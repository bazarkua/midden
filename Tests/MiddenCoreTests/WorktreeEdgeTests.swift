import Foundation
import Testing
@testable import MiddenCore

private func auditWorktree(
    _ home: TempDir, _ path: String, git: String? = Command.git()
) throws -> WorktreeAudit {
    let relative = String(path.dropFirst(home.path.count + 1))
    guard case .directory(.worktree(let match)?, _) = try reclassify(home, relative) else {
        throw ShellError(command: "not a worktree: \(path)", status: 1)
    }
    var auditor = WorktreeAuditor(processes: ProcessDirectories(processes: []), activeWindow: 0)
    auditor.git = git
    return auditor.audit(match)
}

private func check(_ audit: WorktreeAudit, _ id: String) -> SafetyCheck? {
    audit.checks.first { $0.id == id }
}

@Suite struct WorktreeEdgeTests {
    /// A repository with a submodule, and a linked worktree with the
    /// submodule checked out.
    private func repositoryWithSubmodule(_ home: TempDir) throws -> (repository: String, worktree: String) {
        let library = try makeRepository(home, "library")
        let repository = try makeRepository(home)
        try sh(["git", "-C", repository, "-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "lib"])
        try sh(["git", "-C", repository, "commit", "-q", "-m", "Add the library"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init"])
        return (repository, worktree)
    }

    /// A checked-out submodule blocks removal, changed or not, whatever
    /// the user told git about submodules: git refuses to remove the
    /// worktree unless forced, and forcing it deletes the worktree's copy
    /// of the submodule's repository. Status doesn't go into it, since the
    /// submodule's own configuration can define filters.
    @Test func aDirtySubmoduleBlocksRemovalWhateverTheConfig() throws {
        let home = try TempDir("home")
        let (repository, worktree) = try repositoryWithSubmodule(home)
        try home.write("worktrees/feature/lib/README.md", text: "changed inside the submodule\n")
        try sh(["git", "-C", repository, "config", "diff.ignoreSubmodules", "all"])
        // What the config does to a plain status: the change is hidden.
        let plain = Command.run(["git", "-C", worktree, "status", "--porcelain"], environment: Command.quietGit)
        #expect(plain.succeeded && plain.output.isEmpty, "\(plain.output)")

        let audit = try auditWorktree(home, worktree)
        #expect(check(audit, "submodules")?.passed == false)
        #expect(check(audit, "submodules")?.detail.contains("lib is a submodule checked out here") == true)
        #expect(audit.safety == .info)
        #expect(!audit.action.isAutomatic)
        // The submodule inside isn't a worktree of its own.
        guard case .inside(let ancestor, _) = try reclassify(home, "worktrees/feature/lib") else {
            Issue.record("the submodule was classified on its own")
            return
        }
        #expect(ancestor == worktree)
    }

    /// The audit only looks: git status must not rewrite the worktree's
    /// index, even when the files' timestamps would make git refresh it.
    @Test func auditingLeavesTheIndexUntouched() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let index = repository + "/.git/worktrees/feature/index"
        // Tracked files with new timestamps and the same content: a plain
        // `git status` refreshes the index's stat data and writes it.
        try home.touch("worktrees/feature/README.md", daysAgo: -1)
        try home.touch("worktrees/feature/.gitignore", daysAgo: -1)
        let before = try Data(contentsOf: URL(fileURLWithPath: index))
        var info = stat()
        lstat(index, &info)
        let modifiedBefore = info.st_mtimespec

        _ = try auditWorktree(home, worktree)
        #expect(try Data(contentsOf: URL(fileURLWithPath: index)) == before)
        lstat(index, &info)
        #expect(info.st_mtimespec.tv_sec == modifiedBefore.tv_sec)
        #expect(info.st_mtimespec.tv_nsec == modifiedBefore.tv_nsec)

        // The fixture does make git want to write: a plain status, allowed
        // to take optional locks, rewrites the same index.
        _ = Command.run(["git", "-C", worktree, "status"], environment: ["GIT_OPTIONAL_LOCKS": "1"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: index)) != before)
    }

    /// The repository is there but no longer lists the worktree (it was
    /// pruned, or the record was deleted): saying the repository is gone
    /// would be wrong.
    @Test func aMissingWorktreeRecordIsNotAMissingRepository() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try FileManager.default.removeItem(atPath: repository + "/.git/worktrees/feature")

        let audit = try auditWorktree(home, worktree)
        #expect(audit.safety == .info)
        #expect(!audit.action.isAutomatic)
        let record = try #require(audit.checks.first)
        #expect(!record.passed)
        #expect(!record.detail.contains("no longer exists"), "\(record.detail)")
        #expect(record.detail.contains("doesn't list this worktree"), "\(record.detail)")
    }

    /// The record is there but can't be read: that's not "gone", it's
    /// "couldn't check", and nothing is removable.
    @Test func anUnreadableWorktreeRecordIsCouldntVerifyNotGone() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let admin = repository + "/.git/worktrees"
        chmod(admin, 0o000)
        defer { chmod(admin, 0o755) }

        let audit = try auditWorktree(home, worktree)
        #expect(audit.safety == .info)
        #expect(!audit.action.isAutomatic)
        let check = try #require(audit.checks.first)
        #expect(!check.passed)
        #expect(check.detail.contains("couldn't check"), "\(check.detail)")
        #expect(!check.detail.contains("no longer exists"), "\(check.detail)")
        #expect(!check.detail.contains("doesn't list"), "\(check.detail)")
    }

    /// Without git nothing can be checked, so nothing is removable.
    @Test func withoutGitAWorktreeIsOnlyExplained() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let audit = try auditWorktree(home, worktree, git: nil)
        #expect(audit.safety == .info)
        #expect(!audit.action.isAutomatic)
        #expect(check(audit, "gitInstalled")?.passed == false)
    }

    /// A worktree of a bare repository whose repository was deleted.
    @Test func aWorktreeOfADeletedBareRepositoryIsAnOrphan() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let bare = home.path("bare.git")
        try sh(["git", "clone", "-q", "--bare", repository, bare])
        let worktree = home.path("worktrees/from-bare")
        try sh(["git", "-C", bare, "worktree", "add", "-q", "-b", "topic", worktree])
        try FileManager.default.removeItem(atPath: bare)

        let audit = try auditWorktree(home, worktree)
        #expect(audit.safety == .info)
        #expect(check(audit, "repositoryExists")?.passed == false)
        #expect(check(audit, "repositoryExists")?.detail.contains("bare.git") == true)
    }
}
