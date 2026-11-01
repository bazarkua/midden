import Foundation

/// Turns classifier matches into the findings the user sees. Shared by the
/// scanner and the cleaner, so both describe an item the same way.
enum Findings {
    /// Folders a project hasn't changed in this long are safe to clean.
    static let projectIdleWindow: TimeInterval = 14 * 86_400

    static func rule(
        _ match: RuleMatch, path: String, bytes: Int64, breakdown: [Slice] = []
    ) -> Finding {
        let rule = match.rule
        let name = (path as NSString).lastPathComponent
        var app: AppHint?
        var appLabel = match.wildcard ?? name
        switch rule.app {
        case .none:
            break
        case .fixed(let hint):
            app = hint
            appLabel = hint.name ?? appLabel
        case .wildcard:
            if let wildcard = match.wildcard {
                let found = Apps.app(forFolder: wildcard)
                app = found.hint
                appLabel = found.label
            }
        }
        func fill(_ template: String) -> String {
            template.replacingOccurrences(of: "{name}", with: name)
                .replacingOccurrences(of: "{app}", with: appLabel)
                .replacingOccurrences(of: "{wildcard}", with: match.wildcard ?? name)
        }
        var safety = rule.safety
        var explanation = fill(rule.explanation)
        var action = rule.action
        // A container is never removed as a whole. A rule written for one
        // says so itself; a wildcard that matched one (a cache folder
        // holding a folder another rule names) gets this instead.
        if match.isContainer, rule.action.isAutomatic {
            safety = .info
            explanation += """
                 Parts of this folder are listed separately, so Midden never deletes it as a \
                whole. This item is what's left.
                """
            action = .manual("Clean the parts Midden lists separately, or remove the rest by hand in Finder.")
        }
        return Finding(
            id: path, category: rule.category, title: fill(rule.title), path: path,
            group: fill(rule.group), bytes: bytes, safety: safety,
            explanation: explanation, action: action, app: app,
            breakdown: breakdown)
    }

    /// Adds what measuring a partly-emptied folder found: whether every
    /// folder inside was read. One that wasn't means the size can be too
    /// low, and Midden doesn't pick the item for "Clean safe items".
    static func measured(_ finding: Finding, _ measure: ContentsMeasure) -> Finding {
        var finding = finding
        let unread = measure.unread
        finding.checks.append(SafetyCheck(
            id: "measured", title: "Read completely", passed: measure.isComplete,
            detail: measure.isComplete
                ? "Every folder inside was read."
                : "Midden couldn't read \(unread) \(unread == 1 ? "folder" : "folders") inside, so the size shown can be too low."))
        if !measure.isComplete, finding.safety == .safe { finding.safety = .review }
        return finding
    }

    /// Adds the "not in use" check to a finding whose rule asks for it. A
    /// program that uses it, or a process listing that isn't complete,
    /// makes it Info: Midden doesn't delete it until that's settled.
    static func checkingUse(_ finding: Finding, _ usage: ProcessUsage, by scope: Rule.InUseBy = .folder) -> Finding {
        guard finding.action.isAutomatic else { return finding }
        var finding = finding
        let title = "Not in use"
        if let failure = usage.failure {
            finding.checks.append(SafetyCheck(
                id: "inUse", title: title, passed: false, detail: "Couldn't check running programs: \(failure)."))
            finding.safety = .info
            finding.action = .manual("Midden couldn't check which programs use it. Scan again to retry.")
            return finding
        }
        let users: [ProcessUsage.Process]
        switch scope {
        case .folder: users = usage.using(finding.path)
        case .gradle:
            // ~/.gradle/caches or ~/.gradle/wrapper/dists: up to ~/.gradle.
            var gradleHome = finding.path
            while !gradleHome.isEmpty, (gradleHome as NSString).lastPathComponent != ".gradle" {
                gradleHome = (gradleHome as NSString).deletingLastPathComponent
                if gradleHome == "/" { gradleHome = ""; break }
            }
            users = usage.gradle(home: gradleHome.isEmpty ? finding.path : gradleHome)
        }
        guard !users.isEmpty else {
            finding.checks.append(SafetyCheck(
                id: "inUse", title: title, passed: true, detail: "No use found in process paths or arguments."))
            return finding
        }
        let named = users.prefix(3).map { "\($0.displayName) (pid \($0.pid))" }.joined(separator: ", ")
        let more = users.count > 3 ? " and \(users.count - 3) more" : ""
        finding.checks.append(SafetyCheck(
            id: "inUse", title: title, passed: false, detail: "\(named)\(more) \(users.count == 1 ? "uses" : "use") it."))
        finding.safety = .info
        let commands = Array(Set(users.map(\.displayName))).sorted().prefix(3).joined(separator: ", ")
        finding.action = .manual("Quit \(commands) first, then scan again.")
        return finding
    }

    static func buildFolder(
        _ match: BuildFolderMatch, path: String, bytes: Int64, breakdown: [Slice] = [],
        now: Date = Date(), idleWindow: TimeInterval = projectIdleWindow
    ) -> Finding {
        let name = (path as NSString).lastPathComponent
        let project = match.projectName
        var checks: [SafetyCheck] = []
        let lastChange = match.projectLastChange.map { Date(timeIntervalSince1970: $0) }
        let idleDays = Int(idleWindow / 86_400)
        let idle: Bool
        if let lastChange {
            idle = now.timeIntervalSince(lastChange) >= idleWindow
            checks.append(SafetyCheck(
                id: "projectIdle", title: "Project unchanged for \(idleDays) days", passed: idle,
                detail: "Last change in “\(project)” was \(Dates.describe(lastChange, now: now))."))
        } else {
            idle = true
        }
        if match.kind == .pythonEnvironment {
            let recorded = !match.markers.isDisjoint(with: [.pythonRequirements, .uvLock])
            checks.append(SafetyCheck(
                id: "packagesRecorded", title: "Packages are written down", passed: recorded,
                detail: recorded
                    ? "“\(project)” has a requirements, pyproject.toml or lock file to reinstall from."
                    : "“\(project)” has no requirements.txt, pyproject.toml or lock file."))
        }
        return Finding(
            id: path, category: .buildFolders, title: "\(name) in \(project)", path: path,
            group: project, bytes: bytes,
            safety: idle && !match.kind.alwaysReview ? .safe : .review,
            explanation: match.kind.explanation(project: project, markers: match.markers),
            checks: checks, action: match.kind.contents == nil ? .removeDirectory : .removeContents,
            lastActivity: lastChange,
            breakdown: breakdown)
    }

    static func worktree(
        _ match: WorktreeMatch, audit: WorktreeAudit, home: String, bytes: Int64,
        breakdown: [Slice] = []
    ) -> Finding {
        let name = (match.path as NSString).lastPathComponent
        let creator = WorktreeCreator.identify(match.path, home: home)
        let kind = creator.map { "\($0.tool) worktree" } ?? "Worktree"
        let title = audit.branch.map { $0 == name ? "\(kind) \(name)" : "\(kind) \(name) (\($0))" }
            ?? "\(kind) \(name)"
        let explanation = WorktreeAuditor.explanation(
            repositoryName: audit.repository == nil ? nil : audit.repositoryName,
            branch: audit.branch, removable: audit.action.isAutomatic, creator: creator,
            outsideHome: !match.path.hasPrefix(home + "/"))
        return Finding(
            id: match.path, category: .worktrees, title: title, path: match.path,
            group: audit.repositoryName, bytes: bytes, safety: audit.safety,
            explanation: explanation, checks: audit.checks, action: audit.action,
            lastActivity: audit.lastActivity, breakdown: breakdown)
    }

    /// - Parameter otherNames: other paths of the same file (hard links).
    static func file(
        _ match: FileMatch, path: String, entry: DirectoryEntry, otherNames: [String] = []
    ) -> Finding {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let modified = Date(timeIntervalSince1970: entry.modified)
        var explanation: String
        let safety: Safety
        let action: CleanAction
        switch match {
        case .installer:
            explanation = installerExplanation((entry.name as NSString).pathExtension.lowercased())
            safety = .review
            action = .moveToTrash
        case .largeFile:
            explanation = """
                A single large file. Midden can't tell whether you still need it, so it never \
                deletes it for you. If you don't, move it to the Trash: you can still get it back \
                until you empty the Trash.
                """
            safety = .info
            action = .moveToTrash
        }
        if entry.linkCount > 1 {
            explanation += """
                 The same file has \(entry.linkCount) names (hard links); deleting one frees no \
                space while another remains.
                """
            if !otherNames.isEmpty {
                explanation += " Also at " + otherNames.prefix(3).joined(separator: ", ") + "."
            }
        }
        return Finding(
            id: path, category: .largeFiles, title: entry.name, path: path, group: folder,
            bytes: entry.allocatedSize, safety: safety, explanation: explanation, action: action,
            lastActivity: modified)
    }

    private static func installerExplanation(_ ext: String) -> String {
        switch ext {
        case "dmg":
            "A disk image, usually an app installer. Once the app is installed you don't need it, and you can usually download it again from where you got it."
        case "pkg":
            "An installer package. Once it's installed you don't need it, and you can usually download it again from where you got it."
        case "iso":
            "A disk image, often an operating system installer. Check that no virtual machine still uses it before deleting it."
        case "ipsw":
            "A software image for restoring or updating an iPhone, iPad or Mac. Finder downloads a current one when it needs it."
        case "xip":
            "A signed archive, usually an Xcode download. Once it's expanded you don't need it."
        default:
            "An installer you may no longer need."
        }
    }

    static func simulator(_ device: SimulatorDevice, path: String, bytes: Int64) -> Finding {
        Finding(
            id: "sim:\(device.udid)", category: .developerTools,
            title: "\(device.name) simulator (\(device.runtimeName))", path: path,
            group: "Simulator", bytes: bytes, safety: .safe,
            explanation: """
                A simulator that Xcode marks unavailable, usually because its \(device.runtimeName) \
                runtime is no longer installed, so it can't run. Deleting it removes the apps and \
                data in it.
                """,
            checks: [SafetyCheck(
                id: "simulatorUnavailable", title: "Unavailable", passed: true,
                detail: device.availabilityError ?? "simctl reports it as unavailable.")],
            action: .run(["xcrun", "simctl", "delete", device.udid]))
    }

    /// The largest immediate children, biggest first, with the rest as "Other".
    static func breakdown<Mark>(total: Int64, children: [SizedDirectory<Mark>.Child]) -> [Slice] {
        let top = children.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(6)
        var slices = top.map { Slice(name: $0.name, bytes: $0.bytes) }
        let other = total - slices.reduce(0) { $0 + $1.bytes }
        if other > 0, !slices.isEmpty { slices.append(Slice(name: "Other", bytes: other)) }
        return slices
    }
}
