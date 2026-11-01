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

    init(home: URL) throws {
        self.home = try System.canonicalPath(home.path)
    }

    func plan(_ id: String) -> CleanPlan {
        switch validate(id) {
        case .success(let finding):
            return CleanPlan(id: id, finding: finding, refusal: nil)
        case .failure(let refusal):
            return CleanPlan(id: id, finding: refusal.finding, refusal: refusal.message)
        }
    }

    func clean(_ id: String) -> CleanResult {
        let plan = plan(id)
        guard let finding = plan.finding, plan.refusal == nil else {
            return CleanResult(id: id, ok: false, message: plan.refusal ?? "Not recognized.")
        }
        let failure = perform(finding)
        // A trashed item still takes its space until the Trash is emptied.
        if finding.action == .moveToTrash {
            return CleanResult(id: id, ok: failure == nil, message: failure, movedToTrash: failure == nil)
        }
        let freed = max(finding.bytes - Self.allocatedSize(finding.path), 0)
        return CleanResult(id: id, ok: failure == nil, message: failure, freedBytes: freed)
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

    private func refuse(_ message: String, _ finding: Finding? = nil) -> Result<Finding, Refusal> {
        .failure(Refusal(message: message, finding: finding))
    }

    func validate(_ id: String) -> Result<Finding, Refusal> {
        let finding: Finding
        if id.hasPrefix("sim:") {
            switch simulator(String(id.dropFirst(4))) {
            case .success(let found): finding = found
            case .failure(let refusal): return .failure(refusal)
            }
        } else {
            switch fileSystemItem(id) {
            case .success(let found): finding = found
            case .failure(let refusal): return .failure(refusal)
            }
        }
        if case .manual(let instructions) = finding.action {
            return refuse("Midden doesn't delete this itself. \(instructions)", finding)
        }
        if let app = finding.app, let running = Apps.running(app) {
            return refuse("\(running) is running. Quit it first.", finding)
        }
        return .success(finding)
    }

    private func fileSystemItem(_ path: String) -> Result<Finding, Refusal> {
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
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return refuse(errno == ENOENT ? "It no longer exists." : String(cString: strerror(errno)))
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            return refuse("It's a symbolic link.")
        }
        // Catches a symlink anywhere above it, e.g. ~/link/Caches/x.
        guard (try? System.canonicalPath(path)) == path else {
            return refuse("Its path goes through a symbolic link.")
        }

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
        case .inside(let ancestor, _):
            return refuse("It's inside \(ancestor), which Midden treats as one item.")
        case .file(let match?, let entry, _):
            return .success(Findings.file(match, path: path, entry: entry))
        case .file(nil, _, _), .directory(nil, _):
            return refuse("Midden doesn't recognize it as something it can clean.")
        case .directory(let match?, _):
            let bytes = (try? Walker(root: path, delegate: SizeOnly()).run().totalBytes) ?? 0
            switch match {
            case .rule(let rule):
                return .success(Findings.rule(rule, path: path, bytes: bytes))
            case .buildFolder(let build):
                return .success(Findings.buildFolder(build, path: path, bytes: bytes))
            case .worktree(let worktree):
                let audit = WorktreeAuditor(processes: .current()).audit(worktree)
                return .success(Findings.worktree(worktree, audit: audit, home: home, bytes: bytes))
            }
        }
    }

    /// Outside home, only a linked worktree of a repository inside home is
    /// accepted, and only when the link is proven both ways again now.
    private func externalWorktree(_ path: String) -> Result<Finding, Refusal> {
        switch ExternalWorktrees.verify(path, home: home) {
        case .failure(let unproven):
            return refuse("It's outside your home folder and isn't a worktree of a repository in it: \(unproven.reason)")
        case .success(let worktree):
            let bytes = (try? Walker(root: path, delegate: SizeOnly()).run().totalBytes) ?? 0
            let audit = WorktreeAuditor(processes: .current()).audit(worktree)
            return .success(Findings.worktree(worktree, audit: audit, home: home, bytes: bytes))
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

    /// Returns nil on success, else what went wrong.
    func perform(_ finding: Finding) -> String? {
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
            if finding.category == .worktrees {
                // git's file watcher, if one runs for this worktree. It fails
                // harmlessly when none does or git lacks the feature.
                _ = Command.run(
                    ["git", "-C", finding.path, "fsmonitor--daemon", "stop"],
                    environment: Command.quietGit, timeout: 30)
            }
            let result = Command.run(
                arguments, environment: arguments.first == "git" ? Command.quietGit : [:], timeout: 600)
            guard result.succeeded else {
                let output = result.message
                return output.isEmpty ? "\(arguments[0]) exited with status \(result.status)." : output
            }
            return nil
        }
    }
}
