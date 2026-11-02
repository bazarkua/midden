import Foundation
import Synchronization

/// Other repositories and Python environments inside a folder Midden would
/// delete whole: a build folder, or a worktree, whose removal deletes its
/// ignored files too. Neither a build tool's name nor `git status` says
/// anything about them: a clone with commits that exist nowhere else can
/// sit in node_modules, or in an ignored folder of a worktree. Filled from
/// the listings a walk makes anyway, one name comparison per entry.
final class NestedContent: Sendable {
    struct Found: Sendable, Equatable {
        /// Folders holding `.git`, `.hg` or `.svn`, relative to the root
        /// ("" for the root itself): the first few, and how many.
        var repositories: [String] = []
        var repositoryCount = 0
        /// Package checkouts SwiftPM or Xcode made (`.build/checkouts/*`,
        /// `SourcePackages/checkouts/*`), which they clone again.
        var checkouts: [String] = []
        var checkoutCount = 0
        /// Folders holding a `pyvenv.cfg`.
        var environments: [String] = []
        var environmentCount = 0
        /// Folders the walk should have listed but didn't, or listed only
        /// partly: what's in them is unknown.
        var unread = 0
    }

    static let sampleLimit = 3

    let root: String
    /// A worktree's own `.git` file is its link to the repository, not
    /// another repository.
    let isWorktree: Bool
    /// Names at the root that aren't deleted (SwiftPM's `.build` keeps its
    /// checkouts), so nothing in them counts.
    let kept: Set<String>
    /// The walk doesn't leave this device; nil when it's unknown.
    let device: Int32?

    private struct State {
        var found = Found()
        var expected = 0
        var visited = 0
        var partial = 0
        /// Until the root's own listing is added, nothing is known.
        var rootSeen = false
    }
    private let state = Mutex(State())

    init(root: String, isWorktree: Bool, kept: Set<String> = [], device: Int32?) {
        self.root = root
        self.isWorktree = isWorktree
        self.kept = kept
        self.device = device
    }

    /// Adds one listed folder: the root or one inside it.
    /// - Parameter skipped: subfolders the walk won't list (unreadable ones).
    func add(path: String, entries: [DirectoryEntry], isComplete: Bool, skipped: [String] = []) {
        let isRoot = path == root
        let relative = isRoot ? "" : String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if let top = components.first, kept.contains(top) { return }
        var repository = false
        var environment = false
        var expected = 0
        for entry in entries {
            if isRoot, kept.contains(entry.name) { continue }
            switch entry.name {
            case ".git": if !(isRoot && isWorktree) { repository = true }
            case ".hg", ".svn": repository = true
            case "pyvenv.cfg": environment = true
            default: break
            }
            if entry.kind == .directory, device == nil || entry.device == device, !skipped.contains(entry.name) {
                expected += 1
            }
        }
        let checkout = components.count >= 3 && components[components.count - 2] == "checkouts"
            && [".build", "SourcePackages"].contains(components[components.count - 3])
        state.withLock { state in
            state.expected += expected
            if isRoot { state.rootSeen = true } else { state.visited += 1 }
            if !isComplete { state.partial += 1 }
            state.partial += skipped.count
            func note(_ samples: inout [String], _ count: inout Int) {
                count += 1
                if samples.count < Self.sampleLimit { samples.append(relative) }
            }
            if repository, checkout {
                note(&state.found.checkouts, &state.found.checkoutCount)
            } else if repository {
                note(&state.found.repositories, &state.found.repositoryCount)
            }
            if environment { note(&state.found.environments, &state.found.environmentCount) }
        }
    }

    var found: Found {
        state.withLock { state in
            var found = state.found
            found.unread = max(state.expected - state.visited, 0) + state.partial + (state.rootSeen ? 0 : 1)
            found.repositories.sort()
            found.checkouts.sort()
            found.environments.sort()
            return found
        }
    }

    /// Walks `root` the way the cleaner sizes it, and returns its size with
    /// what's inside. Nil when the walk failed.
    static func survey(
        _ root: String, isWorktree: Bool, kept: Set<String> = [], threadCount: Int = WalkDefaults.threadCount,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> (bytes: Int64, found: Found, children: [SizedDirectory<Never>.Child])? {
        var info = stat()
        let device: Int32? = lstat(root, &info) == 0 ? info.st_dev : nil
        let recorder = NestedContent(root: root, isWorktree: isWorktree, kept: kept, device: device)
        let delegate = Survey(recorder: recorder)
        let walker = Walker(root: root, delegate: delegate, threadCount: threadCount)
        guard let result = try? walker.run(cancellation: cancellation), result.rootError == nil else { return nil }
        return (result.totalBytes, recorder.found, result.root?.children ?? [])
    }

    private struct Survey: WalkDelegate {
        let recorder: NestedContent
        func rootContext() {}
        func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, Never> {
            recorder.add(path: directory.path, entries: directory.entries, isComplete: directory.isComplete)
            return Visit(mark: nil, childContext: ())
        }
    }

    /// The check for a finding, with what it does to the verdict: another
    /// repository makes it Info, since deleting the folder deletes that
    /// repository's work; a package checkout, a Python environment or a
    /// folder Midden couldn't read makes it Review at most.
    static func check(_ found: Found?, path: String, action: CleanAction)
        -> (check: SafetyCheck, safety: Safety?, action: CleanAction?)
    {
        let title = "No other repository inside"
        guard let found else {
            return (SafetyCheck(
                id: "nestedContent", title: title, passed: false,
                detail: "Midden couldn't look inside it, so it can't tell whether it holds another repository."),
                .review, nil)
        }
        func list(_ samples: [String], _ count: Int) -> String {
            samples.map { $0.isEmpty ? "the folder itself" : $0 }.joined(separator: ", ")
                + (count > samples.count ? " and \(count - samples.count) more" : "")
        }
        var details: [String] = []
        if found.repositoryCount > 0 {
            let one = found.repositoryCount == 1
            details.append("It holds \(one ? "a repository" : "\(found.repositoryCount) repositories") Midden can't check: \(list(found.repositories, found.repositoryCount)). Deleting the folder deletes \(one ? "that repository" : "them") with any work in \(one ? "it" : "them").")
        }
        if found.checkoutCount > 0 {
            let one = found.checkoutCount == 1
            details.append("\(list(found.checkouts, found.checkoutCount)) \(one ? "is a package checkout" : "are package checkouts") SwiftPM or Xcode made. \(one ? "It's" : "They're") cloned again when needed, but edits and commits made in \(one ? "it" : "them") would be lost.")
        }
        if found.environmentCount > 0 {
            details.append("It holds a Python virtual environment (\(list(found.environments, found.environmentCount))). Packages installed into it by hand aren't recorded anywhere.")
        }
        if found.unread > 0 {
            details.append("Midden couldn't read \(found.unread) \(found.unread == 1 ? "folder" : "folders") in it, so it can't tell whether it holds another repository.")
        }
        guard !details.isEmpty else {
            return (SafetyCheck(
                id: "nestedContent", title: title, passed: true,
                detail: "No other git repository or Python environment is inside it."), nil, nil)
        }
        let check = SafetyCheck(id: "nestedContent", title: title, passed: false, detail: details.joined(separator: " "))
        guard found.repositoryCount > 0 else { return (check, .review, nil) }
        guard action.isAutomatic else { return (check, .info, nil) }
        let first = found.repositories.first ?? ""
        let inside = WorktreeAuditor.quoted(first.isEmpty ? path : path + "/" + first)
        let then: String
        if case .run(let arguments) = action, arguments.first == "git" {
            then = "then remove the worktree with `\(arguments.map(WorktreeAuditor.quoted).joined(separator: " "))`"
        } else {
            then = "then delete the folder in Finder if you don't need it"
        }
        return (check, .info, .manual("Check \(inside) for work (`git -C \(inside) status` and `git -C \(inside) log --oneline HEAD --not --remotes`), move it out if you need it, \(then)."))
    }
}

extension Finding {
    /// This finding with the nested-content check applied.
    func checkingNested(_ found: NestedContent.Found?) -> Finding {
        var finding = self
        let (check, safety, action) = NestedContent.check(found, path: path, action: self.action)
        finding.checks.append(check)
        if let safety, safety > finding.safety { finding.safety = safety }
        if let action { finding.action = action }
        return finding
    }
}

extension WorktreeAudit {
    /// This audit with the nested-content check applied.
    func checkingNested(_ found: NestedContent.Found?, path: String) -> WorktreeAudit {
        var audit = self
        let (check, safety, action) = NestedContent.check(found, path: path, action: self.action)
        audit.checks.append(check)
        if let safety, safety > audit.safety { audit.safety = safety }
        if let action { audit.action = action }
        return audit
    }
}
