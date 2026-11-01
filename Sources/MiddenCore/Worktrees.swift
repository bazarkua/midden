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
}

/// Checks a worktree the way a careful person would before deleting it:
/// nothing uncommitted, its commits are on a branch, it isn't locked, no
/// program is working in it, and it hasn't been used lately.
struct WorktreeAuditor: Sendable {
    var git: String? = Command.git()
    var processes: ProcessDirectories
    var now = Date()
    /// Worktrees used more recently than this are "review", not "safe".
    var activeWindow: TimeInterval = 7 * 86_400
    /// When the worktree was last used; replaceable in tests.
    var activityDate: @Sendable (_ gitDir: String) -> Date? = { WorktreeAuditor.lastActivity(gitDir: $0) }

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
            let repositoryGitDir = ((worktree.gitDir as NSString).deletingLastPathComponent as NSString)
                .deletingLastPathComponent
            let repositoryPath = (repositoryGitDir as NSString).lastPathComponent == ".git"
                ? (repositoryGitDir as NSString).deletingLastPathComponent : repositoryGitDir
            // The repository is there but its record of this worktree isn't:
            // pruned, or deleted by hand. Git can't check it either way.
            if lstat(repositoryGitDir, &info) == 0 {
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
        func run(_ arguments: String...) -> CommandResult {
            Command.run([git, "-C", path] + arguments, environment: Command.quietGit)
        }

        // Where the repository is, and which branch is checked out.
        let head = run("rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD")
        let headLines = head.output.split(separator: "\n").map(String.init)
        guard head.succeeded, headLines.count == 2 else {
            return blocked(
                worktree, repositoryName: nil, branch: nil, lastActivity: lastActivity,
                checks: [SafetyCheck(id: "gitReadable", title: "Git can read it", passed: false, detail: head.message)],
                steps: ["check it with `git -C \(Self.quoted(path)) status`"], repository: nil)
        }
        let commonDir = headLines[0]
        let branch = headLines[1] == "HEAD" ? nil : headLines[1]
        // `git worktree remove` runs from the main worktree, or from the
        // repository itself when it's bare.
        let repository =
            (commonDir as NSString).lastPathComponent == ".git"
            ? (commonDir as NSString).deletingLastPathComponent : commonDir
        var repositoryName = (repository as NSString).lastPathComponent
        if repositoryName.hasSuffix(".git") { repositoryName.removeLast(4) }

        var checks: [SafetyCheck] = []
        var steps: [String] = []

        // Every option that decides what status shows is given explicitly, so
        // the user's configuration (status.showUntrackedFiles=no, submodule
        // ignore settings) can't hide changes. Ignored files are listed too,
        // an ignored folder as one entry without its contents.
        let status = run(
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none",
            "--ignored=matching")
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
                let count = ignoredEntries.count
                let sample = ignoredEntries.prefix(3).joined(separator: ", ") + (count > 3 ? ", …" : "")
                checks.append(SafetyCheck(
                    id: "ignoredFiles", title: "No ignored files", passed: false,
                    detail: "\(count) \(count == 1 ? "file or folder" : "files or folders") git ignores, which it doesn't count as changes and `git worktree remove` deletes without asking: \(sample). Midden can't tell whether they can be made again, so look before removing it."))
            }
        }

        // Tracked files marked assume-unchanged or skip-worktree: git status
        // doesn't compare them, so an edit to one is invisible to it and to
        // `git worktree remove`. Midden can't check them without changing
        // the user's index, so it doesn't remove the worktree. Skip-worktree
        // files that aren't on disk are a sparse checkout's, and fine.
        let listed = run("ls-files", "-v", "-z")
        if !listed.succeeded {
            checks.append(SafetyCheck(
                id: "hiddenChanges", title: "No changes hidden from git", passed: false,
                detail: listed.message))
            steps.append("check it with `git -C \(Self.quoted(path)) ls-files -v`")
        } else {
            let hidden = Self.hiddenFromStatus(lsFilesVZ: listed.output) { relative in
                var info = stat()
                return lstat(path + "/" + relative, &info) == 0
            }
            if hidden.isEmpty {
                checks.append(SafetyCheck(
                    id: "hiddenChanges", title: "No changes hidden from git", passed: true,
                    detail: "No file present here is marked assume-unchanged or skip-worktree."))
            } else {
                let sample = hidden.prefix(3).joined(separator: ", ") + (hidden.count > 3 ? ", …" : "")
                checks.append(SafetyCheck(
                    id: "hiddenChanges", title: "No changes hidden from git", passed: false,
                    detail: "\(hidden.count) \(hidden.count == 1 ? "file is" : "files are") marked assume-unchanged or skip-worktree, so git status doesn't check \(hidden.count == 1 ? "it" : "them") for changes: \(sample)"))
                steps.append("check those files, and clear the flags with `git update-index --no-assume-unchanged` or `--no-skip-worktree` if they're no longer needed")
            }
        }

        let refs = run(
            "for-each-ref", "--count=1", "--contains", "HEAD", "--format=%(refname:short)",
            "refs/heads", "refs/remotes")
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
        let users = processes.inside(path).filter { !$0.isGitFileMonitor }
        if users.isEmpty, let failure = processes.failure {
            // Not seeing a program here proves nothing if the listing is incomplete.
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: false,
                detail: "Couldn't check running programs: \(failure)."))
            steps.append("scan again, and quit any program that may be working in it")
        } else if users.isEmpty {
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: true,
                detail: watchers.isEmpty
                    ? "No running program has its working directory in it."
                    : "No program is working in it. git's file watcher is running here; Midden stops it before removing."))
        } else {
            let names = users.prefix(3).map { "\($0.command) (pid \($0.pid))" }.joined(separator: ", ")
                + (users.count > 3 ? " and others" : "")
            checks.append(SafetyCheck(
                id: "inUse", title: "Not in use", passed: false, detail: "In use by \(names)."))
            // Named here too, so a refusal explains itself.
            steps.append("quit the programs working in it (\(names))")
        }

        if !steps.isEmpty {
            return blocked(
                worktree, repositoryName: repositoryName, branch: branch, lastActivity: lastActivity,
                checks: checks, steps: steps, repository: repository)
        }

        // An unknown date is not evidence of an idle worktree: the check fails
        // and the verdict stays "review". So does any ignored file.
        let idle = lastActivity.map { now.timeIntervalSince($0) >= activeWindow } ?? false
        checks.append(SafetyCheck(
            id: "lastActivity", title: "Not used lately", passed: idle,
            detail: lastActivity.map { "Last checkout or commit \(Dates.describe($0, now: now))." }
                ?? "Couldn't tell when it was last used."))
        let nothingIgnored = ignoredEntries?.isEmpty == true
        return WorktreeAudit(
            repositoryName: repositoryName, repository: repository, branch: branch, checks: checks,
            safety: idle && nothingIgnored ? .safe : .review,
            action: .run(["git", "-C", repository, "worktree", "remove", path]),
            lastActivity: lastActivity)
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
    static func explanation(
        repositoryName: String?, branch: String?, removable: Bool,
        creator: WorktreeCreator? = nil, outsideHome: Bool = false
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
        return text + " Removing it deletes this folder only; \(kept) in the repository."
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
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let state = field.prefix(2)
            let path = String(field.dropFirst(3))
            if state == "!!" {
                ignored.append(path)
            } else {
                changed.append(path)
            }
            if state.contains("R") || state.contains("C") { _ = fields.next() }
        }
        return (changed, ignored)
    }

    /// Paths in `git ls-files -v -z` output whose changes git status can't
    /// see. Each entry is `<tag> <path>`: a lowercase tag means
    /// assume-unchanged, `S` skip-worktree. A skip-worktree file counts only
    /// when `exists` finds it on disk; a sparse checkout leaves it absent.
    static func hiddenFromStatus(lsFilesVZ output: String, exists: (String) -> Bool) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { field in
            guard field.count > 2, let tag = field.first else { return nil }
            let path = String(field.dropFirst(2))
            if tag.isLowercase { return path }
            if tag == "S" { return exists(path) ? path : nil }
            return nil
        }
    }

    static func quoted(_ path: String) -> String {
        path.contains(where: { " '\"$\\".contains($0) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
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
