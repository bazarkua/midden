import Foundation
import Testing
@testable import MiddenCore

// The worktree checks must not depend on how the user configured git: a
// setting that hides changes from `git status` must not turn into a "no
// uncommitted changes" verdict, nor into git removing a worktree that has
// them.

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func auditWorktree(_ home: TempDir, _ path: String) throws -> WorktreeAudit {
    let relative = String(path.dropFirst(home.path.count + 1))
    guard case .directory(.worktree(let match)?, _) = try reclassify(home, relative) else {
        throw ShellError(command: "not a worktree: \(path)", status: 1)
    }
    return WorktreeAuditor(processes: ProcessDirectories(processes: []), activeWindow: 0).audit(match)
}

private func uncommitted(_ audit: WorktreeAudit) -> SafetyCheck? {
    audit.checks.first { $0.id == "uncommitted" }
}

@Suite struct GitConfigTests {
    @Test func hiddenUntrackedFilesStillBlockRemoval() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        // A user who doesn't want untracked files in `git status` output.
        try sh(["git", "-C", repository, "config", "status.showUntrackedFiles", "no"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/notes/ideas.txt", text: "not committed anywhere")

        let audit = try auditWorktree(home, worktree)
        #expect(uncommitted(audit)?.passed == false)
        #expect(uncommitted(audit)?.detail.contains("notes/ideas.txt") == true, "\(audit.checks)")
        #expect(audit.safety == .info)

        let results = await Cleaner(home: home.url).clean([worktree])
        #expect(results.results.first?.ok == false)
        #expect(exists(home.path("worktrees/feature/notes/ideas.txt")))
    }

    /// Even if every check above missed the file, `git worktree remove`
    /// runs `git status` itself, under the user's configuration.
    @Test func gitItselfSeesHiddenUntrackedFilesWhenMiddenRemoves() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try sh(["git", "-C", repository, "config", "status.showUntrackedFiles", "no"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/unsaved.txt", text: "draft")

        let removal = Command.run(
            ["git", "-C", repository, "worktree", "remove", worktree], environment: Command.quietGit)
        #expect(!removal.succeeded)
        #expect(exists(home.path("worktrees/feature/unsaved.txt")))
    }

    @Test func namesWithNewlinesAndRenamesAreCountedOnce() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/line\nbreak.txt", text: "x")
        try sh(["git", "-C", worktree, "mv", "README.md", "RENAMED.md"])

        let audit = try auditWorktree(home, worktree)
        let detail = try #require(uncommitted(audit)?.detail)
        #expect(detail.hasPrefix("2 changed or untracked files"), "\(detail)")
    }
}
