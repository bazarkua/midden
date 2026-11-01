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

    /// `git status` never shows ignored files, and `git worktree remove`
    /// deletes them without asking. A `.env` or a local database is often
    /// ignored and exists nowhere else, so it keeps a worktree from being
    /// Safe. Build output and caches are recreated and don't.
    @Test func ignoredPersonalFilesMakeAWorktreeReviewNotSafe() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/.gitignore", text: "node_modules/\n__pycache__/\n*.log\n.env\n*.sqlite\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore more"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/node_modules/dep/index.js", bytes: 100)
        try home.write("worktrees/feature/app/__pycache__/main.pyc", bytes: 100)
        try home.write("worktrees/feature/debug.log", bytes: 100)

        let generatedOnly = try auditWorktree(home, worktree)
        #expect(generatedOnly.safety == .safe, "\(generatedOnly.checks)")
        #expect(generatedOnly.checks.first { $0.id == "ignoredFiles" }?.passed == true)

        try home.write("worktrees/feature/.env", text: "API_KEY=only-copy")
        try home.write("worktrees/feature/data/local.sqlite", bytes: 4_096)
        let personal = try auditWorktree(home, worktree)
        #expect(personal.safety == .review)
        let check = try #require(personal.checks.first { $0.id == "ignoredFiles" })
        #expect(!check.passed)
        #expect(check.detail.contains(".env"), "\(check.detail)")
        #expect(check.detail.contains("data/local.sqlite"), "\(check.detail)")
        #expect(!check.detail.contains("node_modules"), "\(check.detail)")
        // Still removable when the user picks it: it's a question, not a block.
        #expect(personal.action.isAutomatic)
    }

    /// Why the check above exists: `git worktree remove`, without --force,
    /// deletes a worktree whose only extra file is an ignored .env.
    @Test func gitRemovesIgnoredFilesWithoutAsking() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/.gitignore", text: ".env\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore .env"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/.env", text: "API_KEY=only-copy")

        let audit = try auditWorktree(home, worktree)
        #expect(audit.safety == .review)
        #expect(audit.checks.first { $0.id == "ignoredFiles" }?.detail.contains(".env") == true)

        let removal = Command.run(
            ["git", "-C", repository, "worktree", "remove", worktree], environment: Command.quietGit)
        #expect(removal.succeeded)
        #expect(!exists(home.path("worktrees/feature/.env")))
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

@Suite struct GitEnvironmentTests {
    /// Started from a git hook, an alias or a shell that exported them,
    /// Midden would inherit variables that make `git -C <worktree> status`
    /// look at another repository or index, or add configuration that
    /// hides changes. None of them may reach the commands it runs.
    @Test func inheritedRepositoryVariablesDontReachGit() {
        let inherited = [
            "HOME": "/Users/me", "LANG": "en_US.UTF-8",
            "GIT_DIR": "/Users/me/other/.git", "GIT_WORK_TREE": "/Users/me/other",
            "GIT_INDEX_FILE": "/Users/me/other/.git/index",
            "GIT_OBJECT_DIRECTORY": "/Users/me/other/.git/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/Users/me/other/.git/objects",
            "GIT_COMMON_DIR": "/Users/me/other/.git", "GIT_NAMESPACE": "ns",
            "GIT_CONFIG_PARAMETERS": "'status.showuntrackedfiles'='no'",
        ]
        let environment = Command.environment(inherited: inherited, overrides: [:], extra: Command.quietGit)
        for name in inherited.keys where name.hasPrefix("GIT_") {
            #expect(environment[name] == nil, "\(name)")
        }
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["GIT_CONFIG_KEY_1"] == "status.showUntrackedFiles")
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
    }

    /// What such variables do when they get through: a dirty worktree reads
    /// as clean, because git checks the other repository.
    @Test func gitDirInTheEnvironmentHidesAWorktreesChanges() throws {
        let home = try TempDir("home")
        let other = try makeRepository(home, "other")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/unsaved.txt", text: "draft")

        func status(_ environment: [String: String]) -> CommandResult {
            Command.run(
                ["git", "-C", worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                environment: environment)
        }
        // Passed as `extra`, the variables reach git the way inherited ones did.
        let redirected = status(Command.quietGit.merging(["GIT_DIR": other + "/.git", "GIT_WORK_TREE": other]) { $1 })
        #expect(redirected.succeeded)
        #expect(!redirected.output.contains("unsaved.txt"))
        #expect(status(Command.quietGit).output.contains("unsaved.txt"))
    }
}
