import Foundation

/// A linked git worktree found during a scan.
struct WorktreeMatch: Sendable, Hashable {
    var path: String
    /// `<repository>/worktrees/<name>`, from the worktree's `.git` file.
    var gitDir: String
}

/// What Midden found out about a worktree before calling it safe.
struct WorktreeAudit: Sendable {
    /// For grouping: the repository's name, or the worktree's own name when
    /// git couldn't tell.
    var repositoryName: String
    /// The main worktree, or the repository itself when it's bare. Nil when
    /// git couldn't tell.
    var repository: String?
    var branch: String?
    var checks: [SafetyCheck]
    var safety: Safety
    var action: CleanAction
    var lastActivity: Date?
    /// The branch of origin every commit here is in ("origin/main"), when
    /// the `integrated` check passed.
    var integratedBase: String? = nil
}

/// Checks a worktree the way a careful person would before deleting it:
/// nothing uncommitted, its commits are in origin's main branch and kept by
/// more than this worktree's own records, nothing is half done, it isn't
/// locked, no program is working in it, and it hasn't been used lately.
///
/// Every git command runs with `Command.quietGit` and the worktree's
/// filters neutralized: git doesn't contact another machine, run a program
/// from the repository's configuration, or write to the repository.
struct WorktreeAuditor: Sendable {
    var git: String? = Command.git()
    var processes: ProcessDirectories
    /// Programs that run from a worktree or name it in their arguments
    /// (`tail -f <worktree>/log`, an editor opened on a file in it) while
    /// working elsewhere. Nil to look at working directories only.
    var usage: ProcessUsage? = nil
    var now = Date()
    /// Worktrees used more recently than this are "review", not "safe".
    var activeWindow: TimeInterval = 7 * 86_400
    /// How recently this Mac must have updated origin's main branch for
    /// "its commits are in origin/main" to count. Product policy, not a
    /// guarantee: a ref's reflog records only changes, so an unchanged
    /// branch fetched yesterday looks older than that, which errs toward
    /// Review.
    var baseFreshness: TimeInterval = 30 * 86_400
    /// When the worktree was last used; replaceable in tests.
    var activityDate: @Sendable (_ gitDir: String) -> Date? = { WorktreeAuditor.lastActivity(gitDir: $0) }
    /// Whether a file is on disk: 0, or lstat's errno; replaceable in tests.
    var lookup: @Sendable (_ path: String) -> Int32 = { WorktreeAuditor.lookupError($0) }

    func audit(_ worktree: WorktreeMatch) -> WorktreeAudit {
        let path = worktree.path
        let lastActivity = activityDate(worktree.gitDir)
        guard let git else {
            return WorktreeAudit(
                repositoryName: (worktree.path as NSString).lastPathComponent, repository: nil,
                branch: nil,
                checks: [SafetyCheck(
                    id: "gitInstalled", title: "Git is installed", passed: false,
                    detail: "Midden needs git to check this worktree for uncommitted work, and found none.")],
                safety: .info,
                action: .manual("Install Xcode or the Command Line Tools to check worktrees (`xcode-select --install`), then scan again."),
                lastActivity: lastActivity)
        }
        // An orphan: the repository it belonged to was deleted or moved, so
        // git can neither check it nor remove it.
        var info = stat()
        if !worktree.gitDir.isEmpty, lstat(worktree.gitDir, &info) != 0 {
            let recordError = errno
            let repositoryGitDir = ((worktree.gitDir as NSString).deletingLastPathComponent as NSString)
                .deletingLastPathComponent
            let repositoryPath = (repositoryGitDir as NSString).lastPathComponent == ".git"
                ? (repositoryGitDir as NSString).deletingLastPathComponent : repositoryGitDir
            let repositoryExists = lstat(repositoryGitDir, &info) == 0
            let repositoryError = errno
            // Only "no such file" means gone. A refusal or an I/O error means
            // Midden couldn't look, which is no evidence either way.
            if recordError != ENOENT || (!repositoryExists && repositoryError != ENOENT) {
                let code = recordError != ENOENT ? recordError : repositoryError
                return WorktreeAudit(
                    repositoryName: (repositoryPath as NSString).lastPathComponent, repository: nil,
                    branch: nil,
                    checks: [SafetyCheck(
                        id: "worktreeRecorded", title: "Its repository lists it", passed: false,
                        detail: "Midden couldn't check its record in \(repositoryPath): \(String(cString: strerror(code))).")],
                    safety: .info,
                    action: .manual("Check that \(repositoryPath) is readable, then scan again."),
                    lastActivity: lastActivity)
            }
            // The repository is there but its record of this worktree isn't:
            // pruned, or deleted by hand. Git can't check it either way.
            if repositoryExists {
                return WorktreeAudit(
                    repositoryName: (repositoryPath as NSString).lastPathComponent, repository: nil,
                    branch: nil,
                    checks: [SafetyCheck(
                        id: "worktreeRecorded", title: "Its repository lists it", passed: false,
                        detail: "Its .git file points into \(repositoryPath), which doesn't list this worktree any more, so nothing can check it for uncommitted work.")],
                    safety: .info,
                    action: .manual("Git can't remove it because its repository no longer lists it. If you don't need its files, delete the folder in Finder."),
                    lastActivity: lastActivity)
            }
            return WorktreeAudit(
                repositoryName: (repositoryPath as NSString).lastPathComponent, repository: nil,
                branch: nil,
                checks: [SafetyCheck(
                    id: "repositoryExists", title: "Its repository exists", passed: false,
                    detail: "Its .git file points into \(repositoryPath), which no longer exists, so nothing can check it for uncommitted work.")],
                safety: .info,
                action: .manual("Git can't remove it because its repository is gone. If you don't need its files, delete the folder in Finder."),
                lastActivity: lastActivity)
        }
        // The work tree is given, not looked up: a worktree's own
        // configuration (`git config --worktree core.worktree <folder>`)
        // could point status at another folder, while `git worktree remove`
        // deletes this one.
        func run(_ arguments: [String], environment: [String: String] = Command.quietGit) -> CommandResult {
            Command.run([git, "-C", path, "--work-tree", path] + arguments, environment: environment)
        }

        // Where the repository and this worktree's own git folder are,
        // whether the history is shallow, and which commit and branch are
        // checked out.
        let head = run([
            "rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir",
            "--is-shallow-repository", "HEAD", "--abbrev-ref", "HEAD",
        ])
        let headLines = head.output.split(separator: "\n").map(String.init)
        guard head.succeeded, headLines.count == 5 else {
            return blocked(
                worktree, repositoryName: nil, branch: nil, lastActivity: lastActivity,
                checks: [SafetyCheck(id: "gitReadable", title: "Git can read it", passed: false, detail: head.message)],
                steps: ["check it with `git -C \(Self.quoted(path)) status`"], repository: nil)
        }
        let commonDir = headLines[0]
        let ownGitDir = headLines[1]
        let shallow = headLines[2] == "true"
        let headCommit = headLines[3]
        let branch = headLines[4] == "HEAD" ? nil : headLines[4]
        // `git worktree remove` runs from the main worktree, or from the
        // repository itself when it's bare.
        let repository =
            (commonDir as NSString).lastPathComponent == ".git"
            ? (commonDir as NSString).deletingLastPathComponent : commonDir
        var repositoryName = (repository as NSString).lastPathComponent
        if repositoryName.hasSuffix(".git") { repositoryName.removeLast(4) }

        // Reading configuration runs nothing. It's read here, not once per
        // repository, because a conditional include can differ per worktree.
        let listing = run(["config", "-z", "--get-regexp", WorktreeGitConfig.pattern])
        guard listing.succeeded || (listing.status == 1 && listing.output.isEmpty) else {
            return blocked(
                worktree, repositoryName: repositoryName, branch: branch, lastActivity: lastActivity,
                checks: [SafetyCheck(
                    id: "gitReadable", title: "Git can read it", passed: false,
                    detail: "Midden couldn't read its git configuration: \(listing.message)")],
                steps: ["check it with `git -C \(Self.quoted(path)) config --list`"], repository: repository)
        }
        let config = WorktreeGitConfig.parse(listing.output)
        let environment = Command.gitEnvironment(neutralizing: config.filters)

        var checks: [SafetyCheck] = []
        var steps: [String] = []

        // The index, with each file's mode, before status: status recurses
        // into checked-out submodules, whose configuration can define
        // filters of its own, so it doesn't when there are any.
        let listed = run(["ls-files", "-s", "-v", "-z"], environment: environment)
        let index = listed.succeeded ? Self.parseIndex(lsFilesSVZ: listed.output) : nil
        let submodules = index.map { Self.checkedOutSubmodules($0, in: path, lookup: lookup) }
        let moduleStore = lookup(ownGitDir + "/modules")
        let skipSubmodules = submodules.map { !$0.present.isEmpty || !$0.unchecked.isEmpty } ?? true
            || moduleStore != ENOENT

        // Every option that decides what status shows is given explicitly, so
        // the user's configuration (status.showUntrackedFiles=no, submodule
        // ignore settings) can't hide changes. Ignored files are listed too,
        // an ignored folder as one entry without its contents.
        let status = run(
            [
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
                skipSubmodules ? "--ignore-submodules=all" : "--ignore-submodules=none", "--ignored=matching",
            ], environment: environment)
        // Ignored files and folders: `git worktree remove` deletes them
        // without asking. Nil when status failed.
        var ignoredEntries: [String]?
        if !status.succeeded {
            checks.append(SafetyCheck(id: "uncommitted", title: "No uncommitted changes", passed: false, detail: status.message))
            steps.append("check it with `git -C \(Self.quoted(path)) status`")
        } else {
            let (changed, ignored) = Self.parseStatus(porcelainZ: status.output)
            ignoredEntries = ignored
            if changed.isEmpty {
                checks.append(SafetyCheck(
                    id: "uncommitted", title: "No uncommitted changes", passed: true,
                    detail: "git status shows no changed or untracked files."))
            } else {
                let sample = changed.prefix(3).joined(separator: ", ") + (changed.count > 3 ? ", …" : "")
                checks.append(SafetyCheck(
                    id: "uncommitted", title: "No uncommitted changes", passed: false,
                    detail: "\(changed.count) changed or untracked \(changed.count == 1 ? "file" : "files"): \(sample)"))
                steps.append("commit or discard the changes")
            }
        }
        // Any ignored entry keeps the worktree out of Safe. Its name proves
        // nothing: an ignored folder is reported as one entry, and one named
        // `build` or `.build` can hold the only copy of something.
        if let ignoredEntries {
            if ignoredEntries.isEmpty {
                checks.append(SafetyCheck(
                    id: "ignoredFiles", title: "No ignored files", passed: true,
                    detail: "git ignores nothing in it, so git status sees every file."))
            } else {
                checks.append(SafetyCheck(
                    id: "ignoredFiles", title: "No ignored files", passed: false,
                    detail: Self.ignoredDetail(ignoredEntries, worktree: path, lookup: lookup)))
            }
        }

        // Tracked files marked assume-unchanged or skip-worktree: git status
        // doesn't compare them, so an edit to one is invisible to it and to
        // `git worktree remove`. Midden can't check them without changing
        // the user's index, so it doesn't remove the worktree. Skip-worktree
        // files that aren't on disk are a sparse checkout's, and fine.
        if let index {
            let (hidden, unchecked) = Self.hiddenFromStatus(index) { relative in
                lookup(path + "/" + relative)
            }
            if hidden.isEmpty, unchecked.isEmpty {
                checks.append(SafetyCheck(
                    id: "hiddenChanges", title: "No changes hidden from git", passed: true,
                    detail: "No file present here is marked assume-unchanged or skip-worktree."))
            } else {
                var details: [String] = []
                if !hidden.isEmpty {
                    let sample = hidden.prefix(3).joined(separator: ", ") + (hidden.count > 3 ? ", …" : "")
                    details.append("\(hidden.count) \(hidden.count == 1 ? "file is" : "files are") marked assume-unchanged or skip-worktree, so git status doesn't check \(hidden.count == 1 ? "it" : "them") for changes: \(sample).")
                }
                if !unchecked.isEmpty {
                    let sample = unchecked.prefix(3).joined(separator: ", ") + (unchecked.count > 3 ? ", …" : "")
                    details.append("Midden couldn't check whether \(unchecked.count) skip-worktree \(unchecked.count == 1 ? "file is" : "files are") on disk: \(sample).")
                }
                checks.append(SafetyCheck(
                    id: "hiddenChanges", title: "No changes hidden from git", passed: false,
                    detail: details.joined(separator: " ")))
                steps.append("check those files, and clear the flags with `git update-index --no-assume-unchanged` or `--no-skip-worktree` if they're no longer needed")
            }
        } else {
            checks.append(SafetyCheck(
                id: "hiddenChanges", title: "No changes hidden from git", passed: false,
                detail: listed.message))
            steps.append("check it with `git -C \(Self.quoted(path)) ls-files -v`")
        }

        // Checked-out submodules: git refuses to remove the worktree unless
        // forced, and forcing it deletes this worktree's copy of each
        // submodule's repository, with commits that exist only there.
        if let submodules, submodules.present.isEmpty, submodules.unchecked.isEmpty, moduleStore == ENOENT {
            checks.append(SafetyCheck(
                id: "submodules", title: "No submodules checked out", passed: true,
                detail: "No submodule is checked out in it."))
        } else {
            var details: [String] = []
            if let present = submodules?.present, !present.isEmpty {
                let names = present.prefix(3).joined(separator: ", ") + (present.count > 3 ? ", …" : "")
                details.append("\(names) \(present.count == 1 ? "is a submodule" : "are submodules") checked out here.")
            }
            if let unchecked = submodules?.unchecked, !unchecked.isEmpty {
                details.append("Midden couldn't check whether \(unchecked.prefix(3).joined(separator: ", ")) \(unchecked.count == 1 ? "is" : "are") checked out.")
            }
            if moduleStore == 0, details.isEmpty {
                details.append("This worktree has its own copy of submodule repositories (in \(ownGitDir)/modules).")
            } else if moduleStore != 0, moduleStore != ENOENT {
                details.append("Midden couldn't check its submodule repositories: \(String(cString: strerror(moduleStore))).")
            }
            if submodules == nil { details.append("Midden couldn't list its files: \(listed.message)") }
            checks.append(SafetyCheck(
                id: "submodules", title: "No submodules checked out", passed: false,
                detail: details.joined(separator: " ") + " Git refuses to remove a worktree with submodules unless forced, and forcing it deletes this worktree's copy of each submodule's repository, with any commits that exist only there. Midden never forces it."))
            steps.append("check each submodule for work (`git -C <submodule> status` and `git -C <submodule> log --oneline HEAD --not --remotes`), then remove the worktree yourself")
        }

        // A rebase, merge, cherry-pick, revert or bisect stopped halfway:
        // removing the worktree throws away the rest of it.
        let operations = Self.operationsInProgress(gitDir: ownGitDir, lookup: lookup)
        if operations.isEmpty {
            checks.append(SafetyCheck(
                id: "operation", title: "Nothing half done", passed: true,
                detail: "No rebase, merge, cherry-pick, revert or bisect is in progress."))
        } else {
            checks.append(SafetyCheck(
                id: "operation", title: "Nothing half done", passed: false,
                detail: operations.joined(separator: " ") + " Removing the worktree throws away the rest of it."))
            steps.append("finish or cancel it (`git -C \(Self.quoted(path)) status` says how)")
        }

        // The checked-out commit: on its own branch when one is checked
        // out, else it must be on some branch to survive removal.
        if let branch {
            checks.append(SafetyCheck(
                id: "onBranch", title: "Commits are on a branch", passed: true,
                detail: "The checked-out commit is on \(branch), which stays in the repository."))
        } else {
            let refs = run(
                ["for-each-ref", "--count=1", "--contains", headCommit, "--format=%(refname:short)",
                 "refs/heads", "refs/remotes"], environment: environment)
            let containing = refs.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !refs.succeeded {
                checks.append(SafetyCheck(id: "onBranch", title: "Commits are on a branch", passed: false, detail: refs.message))
                steps.append("check its commits with `git -C \(Self.quoted(path)) log`")
            } else if containing.isEmpty {
                checks.append(SafetyCheck(
                    id: "onBranch", title: "Commits are on a branch", passed: false,
                    detail: "The checked-out commit isn't on any branch, so removing the worktree could lose it."))
                steps.append("create a branch for its commits (`git -C \(Self.quoted(path)) switch -c <name>`)")
            } else {
                checks.append(SafetyCheck(
                    id: "onBranch", title: "Commits are on a branch", passed: true,
                    detail: "The checked-out commit is on \(containing), which stays in the repository."))
            }
        }

        // Commits nothing but this worktree's own records keeps: made while
        // detached, then left by switching away. Removing the worktree
        // deletes its HEAD reflog, and git later deletes the commits.
        let privateHistory = privateCommits(
            gitDir: ownGitDir, commonDir: commonDir, headCommit: headCommit, config: config)
        switch privateHistory {
        case .none:
            checks.append(SafetyCheck(
                id: "privateHistory", title: "No commits only it remembers", passed: true,
                detail: "Every commit in its record of past checkouts is on a branch, a tag or the main checkout's history."))
        case .commits(let commits, let more):
            let newest = String(commits[0].prefix(12))
            let one = commits.count == 1 && !more
            let count = one ? "1 commit (\(newest)) isn't"
                : "\(more ? "More than \(commits.count)" : "\(commits.count)") commits (newest \(newest)) aren't"
            let them = one ? "it" : "them"
            checks.append(SafetyCheck(
                id: "privateHistory", title: "No commits only it remembers", passed: false,
                detail: "\(count) on any branch or tag, or in the main checkout's history. This worktree's record of past checkouts (its HEAD reflog) keeps \(them); removing the worktree deletes that record, and git can then delete \(them)."))
            steps.append("keep \(them) on a branch (`git -C \(Self.quoted(repository)) branch <name> \(newest)`\(one ? "" : ", and the same for any other line of work")")
        case .refs(let refs):
            checks.append(SafetyCheck(
                id: "privateHistory", title: "No commits only it remembers", passed: false,
                detail: "It has refs that only this worktree keeps (\(refs.prefix(3).joined(separator: ", "))). Removing the worktree deletes them."))
            steps.append("check those refs with `git -C \(Self.quoted(path)) for-each-ref refs/worktree refs/bisect refs/rewritten`")
        case .unknown(let reason):
            checks.append(SafetyCheck(
                id: "privateHistory", title: "No commits only it remembers", passed: false,
                detail: "Midden couldn't check its record of past checkouts: \(reason)"))
            steps.append("check it with `git -C \(Self.quoted(path)) reflog`")
        }

        // Every commit in origin's main branch, as this Mac last recorded
        // it. Being on some branch only keeps the commits on this Mac.
        let integration = integrated(
            headCommit: headCommit, branch: branch, repository: repository, commonDir: commonDir,
            config: config, run: { run($0, environment: environment) })
        checks.append(integration.check)

        // History git can check here: complete, and stored as it's shown.
        var historyProblems: [String] = []
        if shallow {
            historyProblems.append("This repository is a shallow clone, so git on this Mac doesn't have its full history and can't show where these commits are.")
        }
        if config.partialClone {
            historyProblems.append("This repository is a partial clone. Midden only reads objects already on this Mac and never downloads missing ones, so it can't check this history.")
        }
        switch lookup(commonDir + "/info/grafts") {
        case ENOENT: break
        case 0: historyProblems.append("This repository has a grafts file, so the history git shows can differ from the commits it stores.")
        case let code: historyProblems.append("Midden couldn't check for a grafts file: \(String(cString: strerror(code))).")
        }
        checks.append(SafetyCheck(
            id: "historyComplete", title: "Git has its whole history", passed: historyProblems.isEmpty,
            detail: historyProblems.isEmpty
                ? "Not a shallow or partial clone, and no grafts change the history git shows."
                : historyProblems.joined(separator: " ")))

        // Files a configured filter applies to: git stores what the filter
        // makes of them, so a clean status can't prove the files here are
        // what's committed, and Midden doesn't run the filter to find out.
        let filters = filteredFiles(config: config, run: { run($0, environment: environment) })
        checks.append(filters)

        let lockFile = worktree.gitDir + "/locked"
        if FileManager.default.fileExists(atPath: lockFile) {
            let reason = Classifier.readSmallFile(lockFile)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            checks.append(SafetyCheck(
                id: "locked", title: "Not locked", passed: false,
                detail: "Locked with `git worktree lock`" + (reason.isEmpty ? "." : ": \(reason)")))
            steps.append("unlock it with `git worktree unlock` if it's no longer needed")
        } else {
            checks.append(SafetyCheck(id: "locked", title: "Not locked", passed: true, detail: "Nobody locked it with `git worktree lock`."))
        }

        // git's own file watcher isn't a program using the worktree: the
        // cleaner stops it before removing. Anything else counts.
        let watchers = processes.inside(path).filter(\.isGitFileMonitor)
        var users = processes.inside(path).filter { !$0.isGitFileMonitor }
        let others = (usage?.using(path) ?? []).filter { process in
            !(process.command == "git" && process.arguments.contains("fsmonitor--daemon"))
                && !users.contains { $0.pid == process.pid }
        }
        users += others.map { ProcessDirectories.Process(pid: $0.pid, command: $0.displayName, directory: $0.directory) }
        if users.isEmpty, let failure = processes.failure ?? usage?.failure {
            // Not seeing a program here proves nothing if the listing is incomplete.
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: false,
                detail: "Couldn't check running programs: \(failure)."))
            steps.append("scan again, and quit any program that may be working in it")
        } else if users.isEmpty {
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: true,
                detail: (watchers.isEmpty
                    ? "No running program has its working directory in it."
                    : "No program is working in it. git's file watcher is running here; Midden stops it before removing.")
                    + (usage == nil ? "" : " None runs from it or names it in its arguments.")))
        } else {
            let names = users.prefix(3).map { "\($0.command) (pid \($0.pid))" }.joined(separator: ", ")
                + (users.count > 3 ? " and others" : "")
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: false, detail: "In use by \(names)."))
            // Named here too, so a refusal explains itself.
            steps.append("quit the programs working in it (\(names))")
        }

        if !steps.isEmpty {
            var audit = blocked(
                worktree, repositoryName: repositoryName, branch: branch, lastActivity: lastActivity,
                checks: checks, steps: steps, repository: repository)
            audit.integratedBase = integration.base
            return audit
        }

        // An unknown date is not evidence of an idle worktree: the check fails
        // and the verdict stays "review". So does any ignored file, commits
        // Midden couldn't find in origin, history it couldn't check, and
        // files behind a filter.
        let idle = lastActivity.map { now.timeIntervalSince($0) >= activeWindow } ?? false
        checks.append(SafetyCheck(
            id: "lastActivity", title: "Not used lately", passed: idle,
            detail: lastActivity.map { "Last checkout or commit \(Dates.describe($0, now: now))." }
                ?? "Couldn't tell when it was last used."))
        let nothingIgnored = ignoredEntries?.isEmpty == true
        let safe = idle && nothingIgnored && integration.base != nil && historyProblems.isEmpty && filters.passed
        return WorktreeAudit(
            repositoryName: repositoryName, repository: repository, branch: branch, checks: checks,
            safety: safe ? .safe : .review,
            action: .run(["git", "-C", repository, "worktree", "remove", path]),
            lastActivity: lastActivity, integratedBase: integration.base)
    }

    private func blocked(
        _ worktree: WorktreeMatch, repositoryName: String?, branch: String?, lastActivity: Date?,
        checks: [SafetyCheck], steps: [String], repository: String?
    ) -> WorktreeAudit {
        let remove = repository.map { "`git -C \(Self.quoted($0)) worktree remove \(Self.quoted(worktree.path))`" }
            ?? "`git worktree remove`"
        var instructions = steps.joined(separator: ", ")
        instructions = instructions.prefix(1).uppercased() + instructions.dropFirst()
        return WorktreeAudit(
            repositoryName: repositoryName ?? (worktree.path as NSString).lastPathComponent,
            repository: repository, branch: branch, checks: checks, safety: .info,
            action: .manual("\(instructions), then remove it with \(remove)."),
            lastActivity: lastActivity)
    }

    /// - Parameters:
    ///   - creator: the AI tool that made it, when its path shows that.
    ///   - outsideHome: found through its repository's list of worktrees.
    ///   - integratedBase: the branch of origin its commits are in, if any.
    static func explanation(
        repositoryName: String?, branch: String?, removable: Bool,
        creator: WorktreeCreator? = nil, outsideHome: Bool = false, integratedBase: String? = nil
    ) -> String {
        let repository = repositoryName.map { "the “\($0)” repository" } ?? "a git repository"
        var text: String
        if let creator {
            text = "A second checkout of \(repository) that \(creator.tool) made for a parallel task: \(creator.evidence)."
        } else {
            text = """
                A second checkout of \(repository), made with `git worktree add`. AI coding tools \
                like Claude Code and Codex create worktrees for parallel tasks and often leave \
                them behind.
                """
        }
        if outsideHome {
            text += """
                 It's outside your home folder; Midden found it in the repository's list of \
                worktrees and checked that each points to the other.
                """
        }
        guard removable else {
            return text + " Midden won't remove it until the checks below pass."
        }
        let kept = branch.map { "the branch “\($0)” and its commits stay" } ?? "its commits stay on their branch"
        let elsewhere = integratedBase.map { ", and the commits are also in \($0)" }
            ?? ", but Midden couldn't confirm the commits are stored anywhere else"
        return text + " Removing it deletes this folder only; \(kept) in the repository\(elsewhere)."
    }

    /// When the worktree's HEAD last moved. Git appends a line to logs/HEAD,
    /// stamped with the time, on every checkout, commit and reset; the last
    /// line's time is used because tools that rewrite reflogs in bulk (such
    /// as reflog expiry during gc) bump the file's mtime for every worktree
    /// at once. Falls back to the mtime of logs/HEAD, then of HEAD. A
    /// worktree's last commit date would be wrong for one made yesterday
    /// from an old branch.
    static func lastActivity(gitDir: String) -> Date? {
        let log = gitDir + "/logs/HEAD"
        if let time = lastReflogTime(log) {
            return Date(timeIntervalSince1970: time)
        }
        for file in [log, gitDir + "/HEAD"] {
            var info = stat()
            if lstat(file, &info) == 0 {
                return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            }
        }
        return nil
    }

    /// The time of the last entry of a reflog. Each line reads
    /// `<old> <new> <name> <<email>> <unix time> <zone>\t<message>`.
    static func lastReflogTime(_ path: String) -> Double? {
        guard let fd = Classifier.openRegularFile(path) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let length = Int(min(info.st_size, 8_192))
        var buffer = [UInt8](repeating: 0, count: length)
        guard pread(fd, &buffer, length, off_t(info.st_size) - off_t(length)) == length else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
        guard let line = text.split(separator: "\n").last,
            let header = line.split(separator: "\t", maxSplits: 1).first,
            let emailEnd = header.lastIndex(of: ">")
        else { return nil }
        let fields = header[header.index(after: emailEnd)...].split(separator: " ")
        return fields.first.flatMap { Double($0) }
    }

    /// The paths in `git status --porcelain=v1 -z` output: changed or
    /// untracked, and ignored (`!!`). Each entry is `XY <path>` ending in
    /// NUL; a rename or copy is followed by one more NUL-terminated field,
    /// its original path, which isn't a second change.
    static func parseStatus(porcelainZ output: String) -> (changed: [String], ignored: [String]) {
        var changed: [String] = []
        var ignored: [String] = []
        // Bytes, not Characters: a name starting with a combining mark would
        // merge with the space or NUL before it into one Character.
        var fields = output.utf8.split(separator: 0, omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let state = Array(field.prefix(2))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            if state == Array("!!".utf8) {
                ignored.append(path)
            } else {
                changed.append(path)
            }
            if state.contains(UInt8(ascii: "R")) || state.contains(UInt8(ascii: "C")) { _ = fields.next() }
        }
        return (changed, ignored)
    }

    /// The ignored-files check's detail. A dependency tree or build output
    /// that a tool recreates, next to the project file that tool reads, gets
    /// one sentence per kind: what puts it back and what would be lost. So
    /// worktrees that hold only those read the same, and can be added to a
    /// plan together. Anything else is listed by name: Midden can't tell
    /// whether it can be made again. The check fails either way.
    static func ignoredDetail(_ entries: [String], worktree: String, lookup: (String) -> Int32) -> String {
        func exists(_ relative: String) -> Bool { lookup(worktree + "/" + relative) == 0 }
        func beside(_ folder: String, _ names: [String]) -> Bool {
            names.contains { exists(folder.isEmpty ? $0 : folder + "/" + $0) }
        }
        var dependencies: [String: Int] = [:]
        var output: Set<String> = []
        var finderSettings = false
        var other: [String] = []
        for entry in entries {
            let isFolder = entry.hasSuffix("/")
            let trimmed = isFolder ? String(entry.dropLast()) : entry
            let name = (trimmed as NSString).lastPathComponent
            let parent = (trimmed as NSString).deletingLastPathComponent
            switch (name, isFolder) {
            case ("node_modules", true) where beside(parent, ["package.json"]):
                let tool = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun")]
                    .first { beside(parent, [$0.0]) || exists($0.0) }?.1 ?? "npm"
                dependencies["node_modules: reinstalled by `\(tool) install`", default: 0] += 1
            case ("Pods", true) where beside(parent, ["Podfile"]):
                dependencies["Pods: reinstalled by `pod install`", default: 0] += 1
            case (".next", true), (".nuxt", true), (".svelte-kit", true), (".turbo", true), (".parcel-cache", true),
                (".angular", true):
                if beside(parent, ["package.json"]) || exists("package.json") { output.insert(name) } else { other.append(entry) }
            case ("target", true) where beside(parent, ["Cargo.toml"]):
                output.insert(name)
            case (let folder, true) where ["build", ".gradle"].contains(folder)
                && beside(parent, ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]):
                output.insert(name)
            case (".dart_tool", true) where beside(parent, ["pubspec.yaml"]):
                output.insert(name)
            case (".DS_Store", false):
                finderSettings = true
            default:
                other.append(entry)
            }
        }
        var sentences: [String] = []
        if !other.isEmpty {
            let count = other.count
            let sample = other.prefix(3).joined(separator: ", ") + (count > 3 ? ", …" : "")
            sentences.append("\(count) \(count == 1 ? "file or folder" : "files or folders") git ignores, which it doesn't count as changes and `git worktree remove` deletes without asking: \(sample). Midden can't tell whether they can be made again, so look before removing it.")
        }
        for (reason, count) in dependencies.sorted(by: { $0.key < $1.key }) {
            let (head, tail) = reason.split(separator: ":", maxSplits: 1).map(String.init).pair
            sentences.append("\(head)\(count > 1 ? " (\(count) folders)" : ""):\(tail); edits inside \(count > 1 ? "them" : "it"), if any, would be lost.")
        }
        if !output.isEmpty {
            sentences.append("Build output (\(output.sorted().joined(separator: ", "))): the next build recreates it; anything else kept inside would be lost.")
        }
        if finderSettings {
            sentences.append(".DS_Store: removing it may reset custom Finder view settings.")
        }
        return sentences.joined(separator: " ")
    }

    /// One file in the index, from `git ls-files -s -v -z`.
    struct IndexEntry: Sendable, Equatable {
        /// `H` for a normal file, a lowercase letter when assume-unchanged,
        /// `S` when skip-worktree.
        var tag: Character
        var mode: String
        var path: String
    }

    /// Each entry is `<tag> <mode> <object> <stage>\t<path>`, ending in NUL.
    static func parseIndex(lsFilesSVZ output: String) -> [IndexEntry] {
        // Bytes, as in parseStatus.
        output.utf8.split(separator: 0, omittingEmptySubsequences: true).compactMap { field in
            guard let tab = field.firstIndex(of: UInt8(ascii: "\t")), let tag = field.first, tag < 0x80 else { return nil }
            let header = field[..<tab].split(separator: UInt8(ascii: " "))
            guard header.count == 4 else { return nil }
            return IndexEntry(
                tag: Character(Unicode.Scalar(tag)), mode: String(decoding: header[1], as: UTF8.self),
                path: String(decoding: field[field.index(after: tab)...], as: UTF8.self))
        }
    }

    /// Index entries whose changes git status can't see. A lowercase tag
    /// means assume-unchanged, `S` skip-worktree. A skip-worktree file
    /// counts as hidden when `lookup` finds it on disk (returns 0), and is
    /// fine only when it's confirmed absent (ENOENT, ENOTDIR), as a sparse
    /// checkout leaves it. Any other lookup error puts it in `unchecked`:
    /// absence wasn't established, so it blocks too.
    static func hiddenFromStatus(
        _ entries: [IndexEntry], lookup: (String) -> Int32
    ) -> (hidden: [String], unchecked: [String]) {
        var hidden: [String] = []
        var unchecked: [String] = []
        for entry in entries {
            if entry.tag.isLowercase {
                hidden.append(entry.path)
            } else if entry.tag == "S" {
                switch lookup(entry.path) {
                case 0: hidden.append(entry.path)
                case ENOENT, ENOTDIR: break
                case let code: unchecked.append(entry.path + " (\(String(cString: strerror(code))))")
                }
            }
        }
        return (hidden, unchecked)
    }

    /// Submodules (index entries of mode 160000) with a `.git` in the
    /// worktree, and those Midden couldn't look for.
    static func checkedOutSubmodules(
        _ entries: [IndexEntry], in worktree: String, lookup: (String) -> Int32
    ) -> (present: [String], unchecked: [String]) {
        var present: [String] = []
        var unchecked: [String] = []
        for entry in entries where entry.mode == "160000" {
            switch lookup(worktree + "/" + entry.path + "/.git") {
            case 0: present.append(entry.path)
            case ENOENT, ENOTDIR: break
            case let code: unchecked.append(entry.path + " (\(String(cString: strerror(code))))")
            }
        }
        return (present, unchecked)
    }

    /// What's stopped halfway in the worktree's git folder, one sentence
    /// each. Only "no such file" proves an operation isn't there.
    static func operationsInProgress(gitDir: String, lookup: (String) -> Int32) -> [String] {
        let markers = [
            ("rebase-merge", "A rebase is in progress here."),
            ("rebase-apply", "A rebase or `git am` is in progress here."),
            ("MERGE_HEAD", "A merge is in progress here."),
            ("CHERRY_PICK_HEAD", "A cherry-pick is in progress here."),
            ("REVERT_HEAD", "A revert is in progress here."),
            ("sequencer", "A cherry-pick or revert of several commits is in progress here."),
            ("BISECT_LOG", "A bisect is in progress here."),
            ("BISECT_START", "A bisect is in progress here."),
        ]
        var found: [String] = []
        for (name, sentence) in markers {
            switch lookup(gitDir + "/" + name) {
            case ENOENT: continue
            case 0: if !found.contains(sentence) { found.append(sentence) }
            case let code: found.append("Midden couldn't check for \(name): \(String(cString: strerror(code))).")
            }
        }
        return found
    }

    enum PrivateHistory: Sendable, Equatable {
        case none
        /// Newest first; `more` when there were more than listed.
        case commits([String], more: Bool)
        /// Refs kept in the worktree's own git folder.
        case refs([String])
        case unknown(String)
    }

    /// The most commits listed for `privateHistory`, and the most reflog
    /// entries passed to git (about 82 KB of arguments).
    static let privateCommitLimit = 1_000
    static let reflogCommitLimit = 2_000

    /// Commits that only records of past checkouts keep, this worktree's
    /// included: in its HEAD reflog, but not on any branch, tag or other
    /// ref, in any ref's reflog, or in the main checkout's reflog.
    /// `--single-worktree`, run on the common git folder, leaves out every
    /// linked worktree's HEAD reflog while branch reflogs still count. The
    /// checked-out commit's own history is left out too: `onBranch`
    /// covers it.
    func privateCommits(
        gitDir: String, commonDir: String, headCommit: String, config: WorktreeGitConfig
    ) -> PrivateHistory {
        guard let git else { return .unknown("git isn't installed.") }
        // Refs only this worktree has, which removal deletes.
        let ownRefs = Self.regularFiles(under: gitDir + "/refs")
        switch ownRefs {
        case .failure(let failure): return .unknown(failure.reason)
        case .success(let refs) where !refs.isEmpty: return .refs(refs.map { "refs/" + $0 })
        case .success: break
        }
        let commits: [String]
        switch Self.reflogCommits(gitDir + "/logs/HEAD") {
        case .failure(let failure):
            return .unknown(failure.reason)
        case .success(nil):
            // No reflog: nothing but HEAD keeps anything, and onBranch checks HEAD.
            // Except with reftable, where reflogs aren't files Midden reads.
            if config.refStorage?.lowercased() == "reftable" {
                return .unknown("this repository keeps refs in the reftable format, which Midden doesn't read.")
            }
            return .none
        case .success(let found?):
            commits = found
        }
        let others = commits.filter { $0 != headCommit }
        guard !others.isEmpty else { return .none }
        guard others.count <= Self.reflogCommitLimit else {
            return .unknown("it lists more than \(Self.reflogCommitLimit) commits.")
        }
        let result = Command.run(
            [git, "--git-dir=" + commonDir, "rev-list", "--single-worktree", "--ignore-missing",
             "--max-count=\(Self.privateCommitLimit + 1)"] + others + ["--not", "--all", "--reflog", headCommit],
            environment: Command.quietGit)
        guard result.succeeded else { return .unknown(result.message) }
        let found = result.output.split(separator: "\n").map(String.init)
        if found.isEmpty { return .none }
        return .commits(Array(found.prefix(Self.privateCommitLimit)), more: found.count > Self.privateCommitLimit)
    }

    /// Every commit a reflog names, old and new values both, newest entry
    /// first, without repeats or the all-zero id. Nil when there's no
    /// reflog. Fails when it's too big to read whole or not a regular file.
    static func reflogCommits(_ path: String, limit: Int = 16 << 20) -> Result<[String]?, Unchecked> {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT ? .success(nil) : .failure(Unchecked(String(cString: strerror(errno)) + "."))
        }
        guard let fd = Classifier.openRegularFile(path) else { return .failure(Unchecked("it isn't a file Midden can read.")) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0 else { return .failure(Unchecked(String(cString: strerror(errno)) + ".")) }
        guard info.st_size <= limit else { return .failure(Unchecked("it's larger than \(limit >> 20) MB.")) }
        let length = Int(info.st_size)
        var buffer = [UInt8](repeating: 0, count: length)
        guard length == 0 || pread(fd, &buffer, length, 0) == length else { return .failure(Unchecked("it couldn't be read whole.")) }
        var seen = Set<String>()
        var commits: [String] = []
        for line in String(decoding: buffer, as: UTF8.self).split(separator: "\n").reversed() {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { continue }
            for id in [fields[1], fields[0]] {
                guard id.count == 40 || id.count == 64, id.allSatisfy(\.isHexDigit),
                    id.contains(where: { $0 != "0" })
                else { continue }
                if seen.insert(String(id)).inserted { commits.append(String(id)) }
            }
        }
        return .success(commits)
    }

    /// Regular files below `folder`, relative to it. None when it doesn't
    /// exist; fails when part of it can't be read.
    static func regularFiles(under folder: String) -> Result<[String], Unchecked> {
        var info = stat()
        if lstat(folder, &info) != 0 {
            return errno == ENOENT ? .success([]) : .failure(Unchecked("its refs folder: \(String(cString: strerror(errno)))."))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: { _, _ in false })
        else { return .failure(Unchecked("its refs folder couldn't be read.")) }
        var files: [String] = []
        var failed = false
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { failed = true; break }
            if values.isRegularFile == true {
                files.append(String(url.path.dropFirst(folder.count + 1)))
            }
        }
        return failed ? .failure(Unchecked("its refs folder couldn't be read.")) : .success(files.sorted())
    }

    struct Integration {
        var check: SafetyCheck
        /// "origin/main" when the check passed.
        var base: String?
    }

    /// Whether every commit checked out here is in origin's main branch:
    /// the target of refs/remotes/origin/HEAD, never a guessed `main`, from
    /// an origin that isn't a folder on this Mac, updated on this Mac
    /// within `baseFreshness`. Nothing is fetched, so this is what git on
    /// this Mac recorded; failing it means Midden couldn't establish that
    /// the work is merged, never that it isn't.
    func integrated(
        headCommit: String, branch: String?, repository: String, commonDir: String,
        config: WorktreeGitConfig, run: ([String]) -> CommandResult
    ) -> Integration {
        func fail(_ detail: String) -> Integration {
            Integration(
                check: SafetyCheck(id: "integrated", title: "Its commits are in origin", passed: false, detail: detail),
                base: nil)
        }
        let repo = Self.quoted(repository)
        guard let url = config.originURL else {
            return fail("This repository has no remote named origin, so Midden can't tell whether its commits exist anywhere else.")
        }
        // A push to a folder on this Mac moves origin/main too, so where git
        // pushes counts as much as where it fetches from.
        guard !config.originAddresses(url).contains(where: WorktreeGitConfig.isLocal) else {
            return fail("origin, or where git pushes to it, is a folder on this Mac, so being in it doesn't mean the work is stored anywhere else.")
        }
        let symref = run(["for-each-ref", "--format=%(symref)%00%(objectname)", "refs/remotes/origin/HEAD"])
        let fields = symref.output.trimmingCharacters(in: .newlines).split(separator: "\0").map(String.init)
        guard symref.succeeded else { return fail("Midden couldn't read origin's main branch: \(symref.message)") }
        guard fields.count == 2, fields[0].hasPrefix("refs/remotes/origin/"), fields[1].count >= 40 else {
            return fail("Midden doesn't know which branch this repository merges into: origin/HEAD isn't set on this Mac. `git -C \(repo) remote set-head origin --auto` sets it, and it contacts origin.")
        }
        let baseRef = fields[0]
        let baseName = String(baseRef.dropFirst("refs/remotes/".count))
        let baseCommit = fields[1]
        let short = String(baseCommit.prefix(12))
        guard let updated = Self.lastReflogTime(commonDir + "/logs/" + baseRef).map({ Date(timeIntervalSince1970: $0) }),
            updated.timeIntervalSince(now) < 86_400
        else {
            return fail("Midden can't tell when \(baseName) was last updated on this Mac, because git kept no usable record of it. Fetch, then scan again: `git -C \(repo) fetch origin`")
        }
        let when = Dates.describe(updated, now: now)
        guard now.timeIntervalSince(updated) <= baseFreshness else {
            return fail("\(baseName) was last updated on this Mac \(when). Midden doesn't contact origin, so it can't tell whether origin still has these commits. Fetch, then scan again: `git -C \(repo) fetch origin`")
        }
        let ahead = run(["rev-list", "--count", headCommit, "--not", baseCommit])
        guard ahead.succeeded, let count = Int(ahead.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return fail("Midden couldn't compare it with \(baseName): \(ahead.message)")
        }
        if count == 0 {
            return Integration(
                check: SafetyCheck(
                    id: "integrated", title: "Its commits are in origin", passed: true,
                    detail: "Every commit here is in \(baseName) (\(short)), which this Mac last updated \(when). Midden doesn't contact origin, so this is what git on this Mac recorded."),
                base: baseName)
        }
        let who = branch ?? "Its checked-out history"
        let commits = count == 1 ? "1 commit that isn't" : "\(count) commits that aren't"
        let see = "To see \(count == 1 ? "it" : "them"): `git -C \(repo) log --oneline \(short)..\(headCommit.prefix(12))`"
        let pushed = run([
            "for-each-ref", "--count=1", "--contains", headCommit, "--format=%(refname:short)", "refs/remotes/origin",
        ])
        let remoteBranch = pushed.succeeded ? pushed.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let recorded = "This Mac last updated \(baseName) \(when), and Midden doesn't contact origin."
        if !remoteBranch.isEmpty {
            return fail("\(who) has \(commits) in \(baseName) (\(short)). \(count == 1 ? "It is" : "They are") on \(remoteBranch), so \(count == 1 ? "it was" : "they were") pushed, but Midden can't tell from history whether \(count == 1 ? "it was" : "they were") merged: squash and rebase merges leave no trace there. \(recorded) \(see)")
        }
        return fail("\(who) has \(commits) in \(baseName) (\(short)) or on any other branch of origin this Mac knows, so nothing outside this Mac may hold \(count == 1 ? "it" : "them"). \(recorded) \(see)")
    }

    /// Whether files here go through a filter from git configuration. Each
    /// filter that names a program is looked up with an attribute
    /// pathspec, which reads attributes and runs nothing.
    func filteredFiles(config: WorktreeGitConfig, run: ([String]) -> CommandResult) -> SafetyCheck {
        func fail(_ detail: String) -> SafetyCheck {
            SafetyCheck(id: "filters", title: "No files go through git filters", passed: false, detail: detail)
        }
        for name in config.filters.sorted() {
            // A gitattributes value can't hold whitespace, so such a filter never applies.
            if name.contains(where: \.isWhitespace) { continue }
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-+".contains($0) }) else {
                return fail("Midden can't check which files the git filter “\(name)” applies to.")
            }
            let files = run(["ls-files", "-z", "--", ":(attr:filter=\(name))"])
            guard files.succeeded else {
                return fail("Midden couldn't check which files the git filter “\(name)” applies to: \(files.message)")
            }
            let paths = files.output.split(separator: "\0").prefix(4).map(String.init)
            guard !paths.isEmpty else { continue }
            let sample = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? ", …" : "")
            if name == "lfs" {
                return fail("Files here are stored with Git LFS (\(sample)). Git history holds only small pointers to them, and Midden can't check whether origin has the files themselves.")
            }
            return fail("Files here go through the git filter “\(name)” (\(sample)), so what git stores can differ from the files on disk. Midden doesn't run filter programs, so it can't confirm the files match what's committed.")
        }
        return SafetyCheck(
            id: "filters", title: "No files go through git filters", passed: true,
            detail: config.filters.isEmpty
                ? "Its git configuration defines no filter programs."
                : "No file here uses the git filters its configuration defines.")
    }

    /// The environment for `git worktree remove` and the other commands
    /// the cleaner runs in a worktree: `Command.quietGit` with the filters
    /// its configuration defines neutralized, since removal runs a `git
    /// status` of its own.
    static func gitEnvironment(worktree: String, git: String? = Command.git()) -> Result<[String: String], Unchecked> {
        guard let git else { return .failure(Unchecked("git isn't installed.")) }
        let listing = Command.run(
            [git, "-C", worktree, "config", "-z", "--get-regexp", WorktreeGitConfig.pattern],
            environment: Command.quietGit)
        guard listing.succeeded || (listing.status == 1 && listing.output.isEmpty) else {
            return .failure(Unchecked("Midden couldn't read its git configuration: \(listing.message)"))
        }
        return .success(Command.gitEnvironment(neutralizing: WorktreeGitConfig.parse(listing.output).filters))
    }

    /// 0 when something is at `path`, else lstat's errno.
    static func lookupError(_ path: String) -> Int32 {
        var info = stat()
        return lstat(path, &info) == 0 ? 0 : errno
    }

    static func quoted(_ path: String) -> String {
        path.contains(where: { " '\"$\\".contains($0) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}

private extension Array where Element == String {
    /// The first two elements; empty strings for missing ones.
    var pair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}

/// Why Midden couldn't check something, in a sentence for the user.
struct Unchecked: Error, Sendable, Equatable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

/// What one `git config -z --get-regexp` listing in a worktree says,
/// across every file git reads there. Reading configuration runs nothing.
struct WorktreeGitConfig: Sendable, Equatable {
    /// Filters that name a program: `filter.<name>.clean`, `.smudge` or
    /// `.process` with a value.
    var filters: Set<String> = []
    /// origin's first URL, the one git fetches from. Never shown: it can
    /// carry a token.
    var originURL: String?
    /// Every `remote.origin.url`: git pushes to all of them when origin
    /// has no push URL.
    var originURLs: [String] = []
    /// `remote.origin.pushurl`: where git pushes instead, when set.
    var originPushURLs: [String] = []
    /// A promisor remote or `extensions.partialClone`: objects can be
    /// missing, and git would download them.
    var partialClone = false
    var refStorage: String?
    /// `url.<base>.insteadOf`: URLs starting with `prefix` use `base`.
    var rewrites: [Rewrite] = []
    /// `url.<base>.pushInsteadOf`: the same, for pushing only.
    var pushRewrites: [Rewrite] = []

    struct Rewrite: Sendable, Equatable {
        var prefix: String
        var base: String
    }

    static let pattern =
        #"^(remote\.origin\.(url|pushurl)|remote\..*\.promisor|extensions\.(partialclone|refstorage)|filter\..*\.(clean|smudge|process)|url\..*\.(push)?insteadof)$"#

    /// Records end in NUL; a key is followed by a newline and its value, or
    /// by nothing for a key without one. Section and variable names come
    /// lowercased; subsection names (a filter's, a URL) keep their case.
    static func parse(_ output: String) -> WorktreeGitConfig {
        var config = WorktreeGitConfig()
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : nil
            let lower = key.lowercased()
            if lower == "remote.origin.url" {
                if config.originURL == nil { config.originURL = value }
                if let value { config.originURLs.append(value) }
            } else if lower == "remote.origin.pushurl" {
                if let value { config.originPushURLs.append(value) }
            } else if lower.hasPrefix("remote."), lower.hasSuffix(".promisor") {
                if value.map({ ["true", "yes", "on", "1"].contains($0.lowercased()) }) ?? true {
                    config.partialClone = true
                }
            } else if lower == "extensions.partialclone" {
                config.partialClone = true
            } else if lower == "extensions.refstorage" {
                config.refStorage = value
            } else if lower.hasPrefix("filter."), let dot = key.lastIndex(of: "."), let value, !value.isEmpty {
                let name = key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot]
                if !name.isEmpty { config.filters.insert(String(name)) }
            } else if lower.hasPrefix("url."), let dot = key.lastIndex(of: "."), let value {
                let base = key[key.index(key.startIndex, offsetBy: "url.".count)..<dot]
                let rewrite = Rewrite(prefix: value, base: String(base))
                if lower.hasSuffix(".pushinsteadof") {
                    config.pushRewrites.append(rewrite)
                } else {
                    config.rewrites.append(rewrite)
                }
            }
        }
        return config
    }

    /// `url` after git's insteadOf rewriting: the longest matching prefix wins.
    func rewritten(_ url: String) -> String {
        Self.rewritten(url, by: rewrites)
    }

    private static func rewritten(_ url: String, by rewrites: [Rewrite]) -> String {
        guard let rewrite = rewrites.filter({ !$0.prefix.isEmpty && url.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count })
        else { return url }
        return rewrite.base + url.dropFirst(rewrite.prefix.count)
    }

    /// Every address git may fetch origin from or push it to: `fetchURL`
    /// rewritten, and the push URLs, or with none, every URL rewritten for
    /// pushing. Rewritten both ways where git's rules differ by version,
    /// so a folder on this Mac is never missed.
    func originAddresses(_ fetchURL: String) -> [String] {
        var addresses = [rewritten(fetchURL)]
        if originPushURLs.isEmpty {
            for url in originURLs.isEmpty ? [fetchURL] : originURLs {
                addresses += [rewritten(url), Self.rewritten(url, by: pushRewrites)]
            }
        } else {
            for url in originPushURLs {
                addresses += [url, rewritten(url)]
            }
        }
        return addresses
    }

    /// Whether git would read `url` as a folder on this Mac: a `file://`
    /// URL or a path. Anything else with a scheme, or an scp-like
    /// `host:path` with no slash before the colon, is another machine. A
    /// remote helper (`<transport>::<address>`) can't be told apart, so it
    /// counts as local, which makes the check fail.
    static func isLocal(_ url: String) -> Bool {
        if url.contains("::") { return true }
        if let scheme = url.range(of: "://") {
            return url[..<scheme.lowerBound].lowercased() == "file"
        }
        if let colon = url.firstIndex(of: ":"), colon != url.startIndex, !url[..<colon].contains("/") {
            return false
        }
        return true
    }
}

enum Dates {
    /// "today", "yesterday" or "12 days ago", with the date: "12 days ago (Oct 19, 2026)".
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendarDays(from: date, to: now, calendar: calendar)
        let relative =
            switch days {
            case ..<1: "today"
            case 1: "yesterday"
            default: "\(days) days ago"
            }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return "\(relative) (\(formatter.string(from: date)))"
    }

    /// Midnights crossed between two dates, not 24-hour periods: 6 pm
    /// yesterday is "yesterday" at 1 am today.
    static func calendarDays(from date: Date, to now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
