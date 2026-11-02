import Foundation

/// What cleaning one id would do, worked out from scratch.
public struct CleanPlan: Sendable, Hashable {
    public var id: String
    /// The item as Midden sees it now. Nil when the id doesn't qualify.
    public var finding: Finding?
    /// Why Midden won't clean it. Nil when it will.
    public var refusal: String?

    public var isApproved: Bool { refusal == nil && finding != nil }
}

/// Moments in cleaning one item where a test can change the file system.
/// The names follow the planned transaction design (open the item through
/// descriptors, claim its identity, validate, delete relative to the
/// descriptors); today's engine calls them at the matching points:
enum CleanStage: Sendable, CaseIterable {
    /// Before the path is first looked at.
    case beforeOpen
    /// After the path checks (canonical, no symlink), before it's classified.
    case beforeClaim
    /// After it's classified, sized and audited: validation is done.
    case afterClaim
    /// Right before the call that deletes, moves or runs the removal.
    case beforeDelete
}

/// Re-validates each id the way the scanner would classify it, then performs
/// its action. Nothing from an earlier scan is trusted: not the path, not the
/// verdict, not the action.
struct CleanEngine {
    var home: String
    var sandboxed = Sandbox.isActive
    /// Moves a path to the Trash. Replaceable so tests never touch the
    /// user's real Trash.
    var trash: @Sendable (String) throws -> Void = { path in
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
    /// Called at each stage of cleaning a file-system item, so tests can
    /// change the file system at exactly that moment.
    var barrier: @Sendable (CleanStage, String) -> Void = { _, _ in }
    /// The worktree auditor, made fresh for each item; replaceable in tests.
    var makeAuditor: @Sendable () -> WorktreeAuditor = { WorktreeAuditor(processes: .current()) }
    /// The mount table and a path's device; replaceable in tests.
    var mountPoints: @Sendable () -> [String]? = { System.mountPoints() }
    var deviceOf: @Sendable (String) -> dev_t? = { CleanEngine.lstatDevice($0) }
    /// The name of a running app matching a hint, if any. Replaceable so
    /// tests don't depend on the apps open on the Mac running them.
    var runningApp: @Sendable (AppHint) -> String? = { Apps.running($0) }
    /// How a partly-emptied folder is listed to measure it, and how long a
    /// listing may stall; replaceable in tests.
    var contentsLister: ContentsSurvey.Lister = { path, reader throws(POSIXError) in try reader.listing(atPath: path) }
    var contentsStallTimeout: TimeInterval = WalkDefaults.stallTimeout
    /// Reads the user's processes for "not in use" checks.
    var processUsage: @Sendable () -> ProcessUsage = { ProcessUsage.current() }

    init(home: URL) throws {
        self.home = try System.canonicalPath(home.path)
    }

    func plan(_ id: String) -> CleanPlan {
        switch validate(id) {
        case .success(let approved):
            return CleanPlan(id: id, finding: approved.finding, refusal: nil)
        case .failure(let refusal):
            return CleanPlan(id: id, finding: refusal.finding, refusal: refusal.message)
        }
    }

    func clean(_ id: String) -> CleanResult {
        let approved: Approved
        switch validate(id) {
        case .success(let found): approved = found
        case .failure(let refusal): return CleanResult(id: id, ok: false, message: refusal.message)
        }
        let finding = approved.finding
        let (failure, deleted) = perform(approved)
        // A trashed item still takes its space until the Trash is emptied.
        if finding.action == .moveToTrash {
            return CleanResult(id: id, ok: failure == nil, message: failure, movedToTrash: failure == nil)
        }
        let freed = deleted ?? max(finding.bytes - Self.allocatedSize(finding.path), 0)
        return CleanResult(id: id, ok: failure == nil, message: failure, freedBytes: freed)
    }

    /// An item that passed every check, and how its contents are cleaned
    /// when not all of them may go: taken from the rule it matched now.
    struct Approved {
        var finding: Finding
        var contents: ContentsPolicy?
    }

    /// What is on disk at `path` now: 0 when it's gone.
    static func allocatedSize(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }
        return (try? Walker(root: path, delegate: SizeOnly()).run().totalBytes) ?? 0
    }

    struct Refusal: Error {
        var message: String
        var finding: Finding?
    }

    private func refuse<T>(_ message: String, _ finding: Finding? = nil) -> Result<T, Refusal> {
        .failure(Refusal(message: message, finding: finding))
    }

    func validate(_ id: String) -> Result<Approved, Refusal> {
        let finding: Finding
        var contents: ContentsPolicy?
        if id.hasPrefix("sim:") {
            switch simulator(String(id.dropFirst(4))) {
            case .success(let found): finding = found
            case .failure(let refusal): return .failure(refusal)
            }
        } else {
            switch fileSystemItem(id) {
            case .success(let found): (finding, contents) = found
            case .failure(let refusal): return .failure(refusal)
            }
            barrier(.afterClaim, id)
        }
        if case .manual(let instructions) = finding.action {
            return refuse("Midden doesn't delete this itself. \(instructions)", finding)
        }
        if let refusal = volumeRefusal(finding) {
            return refuse(refusal, finding)
        }
        if let app = finding.app, let running = runningApp(app) {
            return refuse("\(running) is running. Quit it first.", finding)
        }
        return .success(Approved(finding: finding, contents: contents))
    }

    /// Why `path` can't be acted on as it is, or nil: it must exist, not be
    /// a symlink, and have no symlink above it (`realpath` gives it back
    /// unchanged), e.g. ~/link/Caches/x.
    static func pathRefusal(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? "It no longer exists." : String(cString: strerror(errno))
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            return "It's a symbolic link."
        }
        guard (try? System.canonicalPath(path)) == path else {
            return "Its path goes through a symbolic link."
        }
        return nil
    }

    /// A folder action needs a folder there, a file action a regular file:
    /// something put in the item's place since validation isn't it.
    static func kindRefusal(_ finding: Finding) -> String? {
        let expected: mode_t
        switch finding.action {
        case .removeDirectory, .removeContents: expected = S_IFDIR
        case .removeFile, .moveToTrash: expected = S_IFREG
        case .run, .manual: return nil
        }
        var info = stat()
        guard lstat(finding.path, &info) == 0 else { return "It no longer exists." }
        return info.st_mode & S_IFMT == expected ? nil : "It changed since Midden checked it."
    }

    private func fileSystemItem(_ path: String) -> Result<(Finding, ContentsPolicy?), Refusal> {
        // The id must already be the canonical absolute path the scanner
        // reports: no `.` or `..` components, no doubled or trailing slashes.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return refuse("Not a canonical absolute path.")
        }
        guard path.hasPrefix(home + "/") else {
            return externalWorktree(path)
        }
        barrier(.beforeOpen, path)
        if let refusal = Self.pathRefusal(path) { return refuse(refusal) }
        barrier(.beforeClaim, path)

        let relative = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        let reader = DirectoryReader()
        let classification: Reclassification
        do {
            classification = try Classifier.reclassify(relative, home: home, reader: reader)
        } catch {
            return refuse("Midden couldn't read it: \(error.localizedDescription)")
        }
        switch classification {
        case .missing:
            return refuse("It no longer exists.")
        case .notScanned(let reason):
            return refuse(reason)
        case .inside(let ancestor, .rule(let container)?) where container.isContainer:
            return refuse("It's inside \(ancestor), and Midden only cleans the parts of that folder it lists separately.")
        case .inside(let ancestor, _):
            return refuse("It's inside \(ancestor), which Midden treats as one item.")
        case .file(let match?, let entry, _):
            return .success((Findings.file(match, path: path, entry: entry), nil))
        case .file(nil, _, _), .directory(nil, _):
            return refuse("Midden doesn't recognize it as something it can clean.")
        case .directory(let match?, let dir):
            switch match {
            case .rule(let rule):
                var bytes = (try? Walker(root: path, delegate: SizeOnly()).run().totalBytes) ?? 0
                // A container shows only what no finding inside it covers,
                // as the scan did. It's refused below either way.
                if rule.isContainer, let relative = dir.relative,
                    let remainder = Containers.remainder(of: path, relative: relative, scope: dir.scope, parent: dir.parent)
                {
                    bytes = remainder
                }
                // Only what the policy deletes, measured now.
                var breakdown: [Slice] = []
                var measure: ContentsMeasure?
                if let policy = rule.rule.contents {
                    let measured = measureContents(policy, path)
                    bytes = measured.bytes
                    breakdown = Findings.breakdown(total: bytes, children: measured.children)
                    measure = measured
                }
                var finding = Findings.rule(rule, path: path, bytes: bytes, breakdown: breakdown)
                if let measure { finding = Findings.measured(finding, measure) }
                if rule.rule.checkInUse { finding = Findings.checkingUse(finding, processUsage(), by: rule.rule.inUseBy) }
                return .success((finding, rule.rule.contents))
            case .buildFolder(let build):
                // What it holds, from a walk of its own: never from the scan.
                let survey = NestedContent.survey(
                    path, isWorktree: false,
                    kept: build.kind == .swiftPMBuild ? BuildFolderKind.swiftPMKept : [])
                var bytes = survey?.bytes ?? 0
                var breakdown: [Slice] = []
                var measure: ContentsMeasure?
                if let policy = build.kind.contents {
                    let measured = measureContents(policy, path)
                    bytes = measured.bytes
                    breakdown = Findings.breakdown(total: bytes, children: measured.children)
                    measure = measured
                }
                var finding = Findings.buildFolder(build, path: path, bytes: bytes, breakdown: breakdown)
                if let measure { finding = Findings.measured(finding, measure) }
                finding = finding.checkingNested(survey?.found)
                if build.kind.checkInUse { finding = Findings.checkingUse(finding, processUsage()) }
                return .success((finding, build.kind.contents))
            case .worktree(let worktree):
                let survey = NestedContent.survey(path, isWorktree: true)
                let audit = makeAuditor().audit(worktree).checkingNested(survey?.found, path: path)
                return .success((Findings.worktree(worktree, audit: audit, home: home, bytes: survey?.bytes ?? 0), nil))
            }
        }
    }

    /// What a contents policy would delete under `path` now.
    private func measureContents(_ policy: ContentsPolicy, _ path: String) -> ContentsMeasure {
        ContentsSurvey.measure(policy, path, now: Date(), stallTimeout: contentsStallTimeout, lister: contentsLister)
    }

    /// Outside home, only a linked worktree of a repository inside home is
    /// accepted, and only when the link is proven both ways again now.
    private func externalWorktree(_ path: String) -> Result<(Finding, ContentsPolicy?), Refusal> {
        switch ExternalWorktrees.verify(path, home: home) {
        case .failure(let unproven):
            return refuse("It's outside your home folder and isn't a worktree of a repository in it: \(unproven.reason)")
        case .success(let worktree):
            let survey = NestedContent.survey(path, isWorktree: true)
            let audit = makeAuditor().audit(worktree).checkingNested(survey?.found, path: path)
            return .success((Findings.worktree(worktree, audit: audit, home: home, bytes: survey?.bytes ?? 0), nil))
        }
    }

    private func simulator(_ udid: String) -> Result<Finding, Refusal> {
        guard UUID(uuidString: udid) != nil else {
            return refuse("Not a simulator id.")
        }
        guard !sandboxed else {
            return refuse("Midden can't check simulators from the App Store version; use `xcrun simctl delete unavailable` in Terminal.")
        }
        guard let devices = Simulators.unavailable(home: home, sandboxed: false) else {
            return refuse("simctl couldn't list simulators.")
        }
        guard let device = devices.first(where: { $0.udid == udid }) else {
            return refuse("simctl doesn't report this simulator as unavailable.")
        }
        let path = Simulators.devicesFolder(home: home) + "/" + udid
        let bytes = (try? Walker(root: path, delegate: SizeOnly()).run().totalBytes) ?? 0
        return .success(Findings.simulator(device, path: path, bytes: bytes))
    }

    /// Why removing `path` could reach another disk, from the list of mount
    /// points, or nil. FileManager's removeItem descends into a disk mounted
    /// inside the folder it removes, empties it, and only then fails with
    /// EBUSY on the mount point, leaving the folder half deleted.
    static func mountRefusal(_ path: String, mountPoints: [String]) -> String? {
        if mountPoints.contains(path) {
            return "A disk is mounted at this folder. Eject it first."
        }
        if mountPoints.contains(where: { $0.hasPrefix(path + "/") }) {
            return "A disk is mounted inside this folder. Eject it first."
        }
        return nil
    }

    /// Checked when validating and again right before acting: no disk is
    /// mounted at or inside the item, and what FileManager deletes or moves
    /// is on the home folder's disk.
    /// Everything that can't be verified is a refusal: an unreadable mount
    /// table, a mount point whose folder can't be resolved, a device that
    /// can't be read.
    func volumeRefusal(_ finding: Finding) -> String? {
        if case .manual = finding.action { return nil }
        guard let table = mountPoints() else {
            return "Midden couldn't read the list of mounted disks."
        }
        guard let resolved = Self.canonicalMountPoints(table) else {
            return "Midden couldn't verify where every disk is mounted."
        }
        if let refusal = Self.mountRefusal(finding.path, mountPoints: table + resolved) {
            return refusal
        }
        if case .run = finding.action { return nil }
        guard let device = deviceOf(finding.path), let homeDevice = deviceOf(home) else {
            return "Midden couldn't check which disk it's on."
        }
        return device == homeDevice ? nil : "It's on a different disk than your home folder."
    }

    /// Mount points with the folders holding them resolved (`/tmp/x` is
    /// `/private/tmp/x`), so they compare with canonical item paths. The
    /// mount point itself isn't resolved: that would reach into the mounted
    /// file system, which can hang. Nil when a folder can't be resolved.
    static func canonicalMountPoints(_ table: [String]) -> [String]? {
        var resolved: [String] = []
        for mountPoint in table {
            guard mountPoint != "/" else {
                resolved.append(mountPoint)
                continue
            }
            let parent = (mountPoint as NSString).deletingLastPathComponent
            guard let folder = try? System.canonicalPath(parent) else { return nil }
            let name = (mountPoint as NSString).lastPathComponent
            resolved.append(folder == "/" ? "/" + name : folder + "/" + name)
        }
        return resolved
    }

    static func lstatDevice(_ path: String) -> dev_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    /// Returns nil on success, else what went wrong, and the bytes deleted
    /// when the action counted them itself (nil: measure what's left).
    func perform(_ approved: Approved) -> (failure: String?, deleted: Int64?) {
        let finding = approved.finding
        if case .manual = finding.action {} else {
            // Validation sized and audited the item, which can take a while:
            // a symlink swapped in above it meanwhile, or a disk mounted in
            // it, must not redirect what follows. This narrows the window to
            // the next few calls; it doesn't close it (see ARCHITECTURE.md).
            if let refusal = Self.pathRefusal(finding.path) { return (refusal, nil) }
            if let refusal = Self.kindRefusal(finding) { return (refusal, nil) }
            if let refusal = volumeRefusal(finding) { return (refusal, nil) }
            barrier(.beforeDelete, finding.path)
        }
        if case .removeContents = finding.action, let policy = approved.contents {
            return ContentsSurvey.clean(policy, finding.path, home: home, now: Date())
        }
        return (performAction(finding), nil)
    }

    private func performAction(_ finding: Finding) -> String? {
        let fileManager = FileManager.default
        switch finding.action {
        case .manual(let instructions):
            return instructions
        case .removeDirectory, .removeFile:
            // removeItem deletes symlinks inside the folder, never what they point to.
            do {
                try fileManager.removeItem(atPath: finding.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .moveToTrash:
            do {
                try trash(finding.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .removeContents:
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: finding.path)
            } catch {
                return error.localizedDescription
            }
            var failures: [String] = []
            for name in names {
                do {
                    try fileManager.removeItem(atPath: finding.path + "/" + name)
                } catch {
                    failures.append(name)
                }
            }
            guard failures.isEmpty else {
                return "Couldn't remove \(failures.count) of \(names.count) items, e.g. \(failures[0])."
            }
            return nil
        case .run(let arguments):
            var environment = arguments.first == "git" ? Command.quietGit : [:]
            if finding.category == .worktrees {
                // `git worktree remove` runs a `git status` of its own, which
                // would run the worktree's filter programs.
                switch WorktreeAuditor.gitEnvironment(worktree: finding.path) {
                case .failure(let failure): return failure.reason
                case .success(let neutralized): environment = neutralized
                }
                // git's file watcher, if one runs for this worktree. It fails
                // harmlessly when none does or git lacks the feature.
                _ = Command.run(
                    ["git", "-C", finding.path, "fsmonitor--daemon", "stop"],
                    environment: environment, timeout: 30)
            }
            let result = Command.run(arguments, environment: environment, timeout: 600)
            guard result.succeeded else {
                let output = result.message
                return output.isEmpty ? "\(arguments[0]) exited with status \(result.status)." : output
            }
            return nil
        }
    }
}
