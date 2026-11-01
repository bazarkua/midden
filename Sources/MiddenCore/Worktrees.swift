import Foundation

/// A linked git worktree found during a scan.
struct WorktreeMatch: Sendable, Hashable {
    var path: String
    /// `<repository>/worktrees/<name>`, from the worktree's `.git` file.
    var gitDir: String
}

/// The working directory of every process we can see, from one lsof run.
struct ProcessDirectories: Sendable {
    struct Process: Sendable, Hashable {
        var pid: Int32
        var command: String
        var directory: String
    }

    var processes: [Process]

    /// Runs `lsof -a -d cwd -F pcn` once.
    static func current() -> ProcessDirectories {
        // lsof exits with 1 when it can't inspect some processes; what it
        // printed is still right.
        parse(Command.run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-F", "pcn"], timeout: 30).output)
    }

    /// Parses lsof's field output: `p<pid>`, `c<command>`, `n<path>` lines.
    static func parse(_ output: String) -> ProcessDirectories {
        var result: [Process] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n": result.append(Process(pid: pid, command: command, directory: value))
            default: break
            }
        }
        return ProcessDirectories(processes: result)
    }

    /// Processes working in `path` or below it.
    func inside(_ path: String) -> [Process] {
        processes.filter { $0.directory == path || $0.directory.hasPrefix(path + "/") }
    }
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
    var git: String? = Command.find("git")
    var processes: ProcessDirectories
    var now = Date()
    /// Worktrees used more recently than this are "review", not "safe".
    var activeWindow: TimeInterval = 7 * 86_400

    func audit(_ worktree: WorktreeMatch) -> WorktreeAudit {
        let path = worktree.path
        let lastActivity = Self.lastActivity(gitDir: worktree.gitDir)
        guard let git else {
            return blocked(
                worktree, repositoryName: nil, branch: nil, lastActivity: lastActivity,
                checks: [SafetyCheck(
                    title: "Git is installed", passed: false,
                    detail: "Midden needs git to check this worktree for uncommitted work.")],
                steps: ["install Git (`xcode-select --install`) and scan again"],
                repository: nil)
        }
        // Optional locks off: `git status` must not rewrite the index of a
        // worktree we're only looking at.
        func run(_ arguments: String...) -> CommandResult {
            Command.run([git, "-C", path] + arguments, environment: ["GIT_OPTIONAL_LOCKS": "0"])
        }

        // Where the repository is, and which branch is checked out.
        let head = run("rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD")
        let headLines = head.output.split(separator: "\n").map(String.init)
        guard head.succeeded, headLines.count == 2 else {
            return blocked(
                worktree, repositoryName: nil, branch: nil, lastActivity: lastActivity,
                checks: [SafetyCheck(title: "Git can read it", passed: false, detail: head.message)],
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

        let status = run("status", "--porcelain")
        if !status.succeeded {
            checks.append(SafetyCheck(title: "No uncommitted changes", passed: false, detail: status.message))
            steps.append("check it with `git -C \(Self.quoted(path)) status`")
        } else {
            let changed = status.output.split(separator: "\n").map { String($0.dropFirst(3)) }
            if changed.isEmpty {
                checks.append(SafetyCheck(
                    title: "No uncommitted changes", passed: true,
                    detail: "git status shows no changed or untracked files."))
            } else {
                let sample = changed.prefix(3).joined(separator: ", ") + (changed.count > 3 ? ", …" : "")
                checks.append(SafetyCheck(
                    title: "No uncommitted changes", passed: false,
                    detail: "\(changed.count) changed or untracked \(changed.count == 1 ? "file" : "files"): \(sample)"))
                steps.append("commit or discard the changes")
            }
        }

        let refs = run(
            "for-each-ref", "--count=1", "--contains", "HEAD", "--format=%(refname:short)",
            "refs/heads", "refs/remotes")
        let containing = refs.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refs.succeeded {
            checks.append(SafetyCheck(title: "Commits are on a branch", passed: false, detail: refs.message))
            steps.append("check its commits with `git -C \(Self.quoted(path)) log`")
        } else if containing.isEmpty {
            checks.append(SafetyCheck(
                title: "Commits are on a branch", passed: false,
                detail: "The checked-out commit isn't on any branch, so removing the worktree could lose it."))
            steps.append("create a branch for its commits (`git -C \(Self.quoted(path)) switch -c <name>`)")
        } else {
            checks.append(SafetyCheck(
                title: "Commits are on a branch", passed: true,
                detail: "The checked-out commit is on \(containing), which stays in the repository."))
        }

        let lockFile = worktree.gitDir + "/locked"
        if FileManager.default.fileExists(atPath: lockFile) {
            let reason = Classifier.readSmallFile(lockFile)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            checks.append(SafetyCheck(
                title: "Not locked", passed: false,
                detail: "Locked with `git worktree lock`" + (reason.isEmpty ? "." : ": \(reason)")))
            steps.append("unlock it with `git worktree unlock` if it's no longer needed")
        } else {
            checks.append(SafetyCheck(title: "Not locked", passed: true, detail: "Nobody locked it with `git worktree lock`."))
        }

        let users = processes.inside(path)
        if users.isEmpty {
            checks.append(SafetyCheck(
                title: "Not in use", passed: true,
                detail: "No running program has its working directory in it."))
        } else {
            let names = users.prefix(3).map { "\($0.command) (pid \($0.pid))" }.joined(separator: ", ")
            checks.append(SafetyCheck(
                title: "Not in use", passed: false,
                detail: "In use by \(names)\(users.count > 3 ? " and others" : "")."))
            steps.append("quit the programs working in it")
        }

        if !steps.isEmpty {
            return blocked(
                worktree, repositoryName: repositoryName, branch: branch, lastActivity: lastActivity,
                checks: checks, steps: steps, repository: repository)
        }

        let recent = lastActivity.map { now.timeIntervalSince($0) < activeWindow } ?? false
        checks.append(SafetyCheck(
            title: "Not used lately", passed: !recent,
            detail: lastActivity.map { "Last checkout or commit \(Dates.describe($0, now: now))." }
                ?? "Midden couldn't tell when it was last used."))
        return WorktreeAudit(
            repositoryName: repositoryName, repository: repository, branch: branch, checks: checks,
            safety: recent ? .review : .safe,
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
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
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

    static func quoted(_ path: String) -> String {
        path.contains(where: { " '\"$\\".contains($0) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}

enum Dates {
    /// "today", "yesterday" or "12 days ago", with the date: "12 days ago (19 Oct 2026)".
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        let relative =
            switch days {
            case ..<1: "today"
            case 1: "yesterday"
            default: "\(days) days ago"
            }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return "\(relative) (\(formatter.string(from: date)))"
    }
}
