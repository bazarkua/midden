import Foundation
import Testing
@testable import MiddenCore

/// A repository with one commit, inside a fake home.
func makeRepository(_ home: TempDir, _ name: String = "repo") throws -> String {
    let repository = try home.mkdir(name)
    try sh(["git", "init", "-q", "-b", "main"], in: repository)
    try home.write("\(name)/README.md", text: "hello\n")
    try home.write("\(name)/.gitignore", text: "node_modules/\n")
    try sh(["git", "add", "."], in: repository)
    try sh(["git", "commit", "-q", "-m", "Initial commit"], in: repository)
    return repository
}

/// Adds a worktree on a new branch and returns its path.
func addWorktree(_ home: TempDir, repository: String, branch: String) throws -> String {
    let path = home.path("worktrees/\(branch)")
    try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", branch, path])
    return path
}

private func audit(
    _ home: TempDir, _ path: String, activeWindow: TimeInterval = 0,
    processes: ProcessDirectories = ProcessDirectories(processes: [])
) throws -> WorktreeAudit {
    let relative = String(path.dropFirst(home.path.count + 1))
    guard case .directory(.worktree(let match)?, _) = try reclassify(home, relative) else {
        throw ShellError(command: "not a worktree: \(path)", status: 1)
    }
    return WorktreeAuditor(processes: processes, activeWindow: activeWindow).audit(match)
}

/// The finding the scanner would show for a worktree inside `home`.
private func finding(_ home: TempDir, _ path: String, activeWindow: TimeInterval = 0) throws -> Finding {
    let match = WorktreeMatch(path: path, gitDir: "")
    let result = try audit(home, path, activeWindow: activeWindow)
    return Findings.worktree(match, audit: result, home: home.path, bytes: 0)
}

private func check(_ audit: WorktreeAudit, _ title: String) -> SafetyCheck? {
    audit.checks.first { $0.title == title }
}

@Suite struct WorktreeTests {
    @Test func cleanWorktreeOnABranchIsSafe() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        // Ignored files, like node_modules, don't make it dirty.
        try home.write("worktrees/feature/node_modules/dep/index.js", bytes: 100)

        let result = try audit(home, worktree)
        #expect(result.safety == .safe)
        #expect(result.checks.allSatisfy { $0.passed })
        #expect(result.action == CleanAction.run(["git", "-C", repository, "worktree", "remove", worktree]))
        #expect(result.repositoryName == "repo")
        #expect(result.branch == "feature")
        #expect(try finding(home, worktree).explanation.contains("the branch “feature” and its commits stay"))
        let lastActivity = try #require(result.lastActivity)
        #expect(abs(lastActivity.timeIntervalSinceNow) < 120)
    }

    @Test func recentlyUsedWorktreeIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let result = try audit(home, worktree, activeWindow: 7 * 86_400)
        #expect(result.safety == .review)
        #expect(check(result, "Not used lately")?.passed == false)
        #expect(result.action.isAutomatic)
    }

    @Test func uncommittedChangesBlockRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/notes.txt", text: "draft")
        try home.write("worktrees/feature/README.md", text: "changed")

        let result = try audit(home, worktree)
        #expect(result.safety == .info)
        #expect(!result.action.isAutomatic)
        let dirty = try #require(check(result, "No uncommitted changes"))
        #expect(!dirty.passed)
        #expect(dirty.detail.contains("2 changed or untracked files"))
    }

    @Test func commitOnNoBranchBlocksRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "switch", "-q", "--detach"])
        try home.write("worktrees/feature/new.txt", text: "work")
        try sh(["git", "-C", worktree, "add", "new.txt"])
        try sh(["git", "-C", worktree, "commit", "-q", "-m", "Detached work"])

        let result = try audit(home, worktree)
        #expect(result.safety == .info)
        #expect(result.branch == nil)
        #expect(check(result, "Commits are on a branch")?.passed == false)
        #expect(check(result, "No uncommitted changes")?.passed == true)
    }

    @Test func detachedHeadOnABranchCommitIsFine() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "switch", "-q", "--detach"])
        let result = try audit(home, worktree)
        #expect(result.safety == .safe)
        #expect(try finding(home, worktree).explanation.contains("its commits stay on their branch"))
    }

    @Test func lockedWorktreeBlocksRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", repository, "worktree", "lock", "--reason", "on a USB drive", worktree])
        let result = try audit(home, worktree)
        #expect(result.safety == .info)
        let locked = try #require(check(result, "Not locked"))
        #expect(!locked.passed)
        #expect(locked.detail.contains("on a USB drive"))
    }

    @Test func worktreeInUseBlocksRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.mkdir("worktrees/feature/src")

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: worktree + "/src")
        try sleeper.run()
        defer { sleeper.terminate() }

        let result = try audit(home, worktree, processes: .current())
        #expect(result.safety == .info)
        let inUse = try #require(check(result, "Not in use"))
        #expect(!inUse.passed)
        #expect(inUse.detail.contains("sleep (pid \(sleeper.processIdentifier))"))
    }

    @Test func bareRepositoryRemovesFromTheRepository() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let bare = home.path("bare.git")
        try sh(["git", "clone", "-q", "--bare", repository, bare])
        let worktree = home.path("worktrees/from-bare")
        try sh(["git", "-C", bare, "worktree", "add", "-q", "-b", "topic", worktree])

        let result = try audit(home, worktree)
        #expect(result.safety == .safe)
        #expect(result.repositoryName == "bare")
        #expect(result.action == CleanAction.run(["git", "-C", bare, "worktree", "remove", worktree]))
    }

    @Test func submodulesAreNotWorktrees() throws {
        let home = try TempDir("home")
        try home.write("app/vendor/lib/.git", text: "gitdir: ../../.git/modules/vendor/lib\n")
        try home.write("app/vendor/lib/code.c", bytes: 10)
        #expect(try reclassify(home, "app/vendor/lib").isNothing)

        try home.write("relative/.git", text: "gitdir: ../repo/.git/worktrees/relative\n")
        guard case .directory(.worktree(let match)?, _) = try reclassify(home, "relative") else {
            Issue.record("relative gitdir not recognized")
            return
        }
        #expect(match.gitDir == home.path("repo/.git/worktrees/relative"))
    }

    @Test func collectsWorkingDirectoriesOfThisUsersProcesses() {
        let entries = [
            ProcessDirectories.Entry(pid: 101, uid: 501, command: "zsh"),
            ProcessDirectories.Entry(pid: 202, uid: 501, command: "node"),
            ProcessDirectories.Entry(pid: 303, uid: 501, command: "gone"),
            ProcessDirectories.Entry(pid: 404, uid: 0, command: "root-daemon"),
        ]
        let directories: [Int32: Result<String, POSIXError>] = [
            101: .success("/Users/me/repo/wt"), 202: .success("/Users/me/repo/wt-other"),
            303: .failure(POSIXError(.ESRCH)), 404: .failure(POSIXError(.EPERM)),
        ]
        let processes = ProcessDirectories.collect(entries, user: 501) { directories[$0]! }
        #expect(processes.failure == nil)
        #expect(processes.processes.count == 2)
        #expect(processes.inside("/Users/me/repo/wt").map { $0.pid } == [101])
        #expect(processes.inside("/Users/me/repo").count == 2)

        // An own process whose directory can't be read makes the listing incomplete.
        let blocked = ProcessDirectories.collect(entries, user: 501) { pid in
            pid == 202 ? .failure(POSIXError(.EPERM)) : directories[pid]!
        }
        #expect(blocked.failure?.contains("node (pid 202)") == true)
    }

    @Test func incompleteProcessListingFailsTheInUseCheck() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let incomplete = ProcessDirectories(processes: [], failure: "the system wouldn't list processes")
        let result = try audit(home, worktree, processes: incomplete)
        #expect(result.safety == .info)
        let inUse = try #require(check(result, "Not in use"))
        #expect(!inUse.passed)
        #expect(inUse.detail.contains("Couldn't check running programs"))
    }

    @Test func listsRealProcessesInProcess() throws {
        let dir = try TempDir()
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        sleeper.currentDirectoryURL = dir.url
        try sleeper.run()
        defer { sleeper.terminate() }
        let processes = ProcessDirectories.current()
        #expect(processes.inside(dir.path).map { $0.pid } == [sleeper.processIdentifier])
        #expect(processes.inside(dir.path).first?.command == "sleep")
    }

    @Test func lastActivityComesFromTheLastReflogEntry() throws {
        let dir = try TempDir()
        let old = Int(Date().timeIntervalSince1970) - 30 * 86_400
        let zero = String(repeating: "0", count: 40)
        try dir.write("logs/HEAD", text: """
            \(zero) \(zero) A <a@example.com> \(old - 100) -0700\tcommit (initial): Start
            \(zero) \(zero) A <a@example.com> \(old) -0700\tcheckout: moving from main to topic

            """)
        // A bulk rewrite of the reflog bumps its mtime, not its entries.
        try dir.touch("logs/HEAD", daysAgo: 0)
        let activity = try #require(WorktreeAuditor.lastActivity(gitDir: dir.path))
        #expect(activity.timeIntervalSince1970 == Double(old))

        // Without a readable entry, fall back to the file's mtime.
        try dir.write("other/logs/HEAD", text: "garbage\n")
        let fallback = try #require(WorktreeAuditor.lastActivity(gitDir: dir.path("other")))
        #expect(abs(fallback.timeIntervalSinceNow) < 120)
    }

    @Test func orphanedWorktreeIsExplained() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home, "gone-repo")
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try FileManager.default.removeItem(atPath: repository)

        let result = try audit(home, worktree)
        #expect(result.safety == .info)
        #expect(result.repositoryName == "gone-repo")
        #expect(check(result, "Its repository exists")?.passed == false)
        guard case .manual(let instructions) = result.action else {
            Issue.record("an orphan must not be removable")
            return
        }
        #expect(instructions.contains("delete the folder in Finder"))
    }
}
