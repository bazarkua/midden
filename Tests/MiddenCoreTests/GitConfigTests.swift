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
    /// Any ignored entry keeps a worktree out of Safe. Its name proves
    /// nothing: `--ignored=matching` reports an ignored folder as one entry
    /// without its contents, and a folder named `build` or `.build` can
    /// hold the only copy of something (a dependency checkout with local
    /// edits, a database, notes).
    @Test func anyIgnoredEntryMakesAWorktreeReviewNotSafe() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write(
            "repo/.gitignore",
            text: "node_modules/\nbuild/\n.swiftpm/\n.venv/\n.build/\n*.log\n.env\n*.sqlite\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore more"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let clean = try auditWorktree(home, worktree)
        #expect(clean.safety == .safe, "\(clean.checks)")
        #expect(clean.checks.first { $0.id == "ignoredFiles" }?.passed == true)

        // Each one alone: (file written, entry git reports).
        let cases = [
            ("node_modules/dep/index.js", "node_modules/"),
            ("build/archive/only-copy.sqlite", "build/"),
            (".swiftpm/configuration/notes.txt", ".swiftpm/"),
            (".venv/lib/python3.12/site-packages/patched.py", ".venv/"),
            (".build/checkouts/dependency/Sources/LocalEdit.swift", ".build/"),
            ("notes.log/today.md", "notes.log/"),
            (".env", ".env"),
        ]
        for (file, entry) in cases {
            try home.write("worktrees/feature/" + file, text: "only copy")
            let audit = try auditWorktree(home, worktree)
            #expect(audit.safety == .review, "\(file)")
            let check = try #require(audit.checks.first { $0.id == "ignoredFiles" })
            #expect(!check.passed, "\(file)")
            #expect(check.detail.contains(entry), "\(file): \(check.detail)")
            #expect(check.detail.contains("can't tell whether they can be made again"), "\(check.detail)")
            // Removable when the user picks it: a question, not a block.
            #expect(audit.action.isAutomatic)
            let top = String(file.prefix { $0 != "/" })
            try FileManager.default.removeItem(atPath: home.path("worktrees/feature/" + top))
        }
    }

    /// A tracked file marked assume-unchanged or skip-worktree can be
    /// edited without `git status` showing it, and `git worktree remove`
    /// then deletes the edit. Midden can't verify such files without
    /// changing the user's index, so it doesn't remove the worktree.
    @Test(arguments: ["--assume-unchanged", "--skip-worktree"])
    func changesHiddenByIndexFlagsBlockRemoval(flag: String) async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "update-index", flag, "README.md"])
        try home.write("worktrees/feature/README.md", text: "edited, and only here\n")
        // What the flag does: status sees nothing.
        let status = Command.run(
            ["git", "-C", worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            environment: Command.quietGit)
        #expect(status.succeeded && status.output.isEmpty)

        let audit = try auditWorktree(home, worktree)
        #expect(audit.safety == .info, "\(flag)")
        #expect(!audit.action.isAutomatic)
        let check = try #require(audit.checks.first { $0.id == "hiddenChanges" })
        #expect(!check.passed)
        #expect(check.detail.contains("README.md"), "\(check.detail)")

        let result = await Cleaner(home: home.url).clean([worktree]).results[0]
        #expect(!result.ok)
        #expect(try String(contentsOfFile: home.path("worktrees/feature/README.md"), encoding: .utf8)
            == "edited, and only here\n")
        // The user's index is left as it was.
        let flagged = try sh(["git", "-C", worktree, "ls-files", "-v", "README.md"])
        #expect(flagged.hasPrefix(flag == "--assume-unchanged" ? "h " : "S "), "\(flagged)")
    }

    /// A sparse checkout marks the files it leaves out skip-worktree; they
    /// aren't on disk, so there's nothing to lose and nothing to block.
    @Test func sparseCheckoutAbsencesDontBlockRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/kept/a.txt", text: "a\n")
        try home.write("repo/left-out/b.txt", text: "b\n")
        try sh(["git", "-C", repository, "add", "."])
        try sh(["git", "-C", repository, "commit", "-q", "-m", "Two folders"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "sparse-checkout", "set", "kept"])
        let flagged = try sh(["git", "-C", worktree, "ls-files", "-v", "left-out/b.txt"])
        #expect(flagged.hasPrefix("S "), "\(flagged)")
        #expect(!FileManager.default.fileExists(atPath: home.path("worktrees/feature/left-out/b.txt")))

        let audit = try auditWorktree(home, worktree)
        #expect(audit.checks.first { $0.id == "hiddenChanges" }?.passed == true, "\(audit.checks)")
        #expect(audit.safety == .safe, "\(audit.checks)")
    }

    /// A skip-worktree file whose lookup fails (permission, I/O) wasn't
    /// shown to be absent, so it can't pass as a sparse checkout's: the
    /// check fails, removal stays manual, and the cleaner refuses.
    @Test(arguments: [EACCES, EIO])
    func aSkipWorktreeFileThatCantBeLookedUpBlocksRemoval(code: Int32) throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/kept/a.txt", text: "a\n")
        try home.write("repo/left-out/b.txt", text: "b\n")
        try sh(["git", "-C", repository, "add", "."])
        try sh(["git", "-C", repository, "commit", "-q", "-m", "Two folders"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "sparse-checkout", "set", "kept"])

        var engine = try CleanEngine(home: home.url)
        engine.makeAuditor = {
            var auditor = WorktreeAuditor(processes: ProcessDirectories(processes: []), activeWindow: 0)
            auditor.lookup = { path in
                path.hasSuffix("/left-out/b.txt") ? code : WorktreeAuditor.lookupError(path)
            }
            return auditor
        }
        let plan = engine.plan(worktree)
        let check = try #require(plan.finding?.checks.first { $0.id == "hiddenChanges" })
        #expect(!check.passed)
        #expect(check.detail.contains("couldn't check"), "\(check.detail)")
        #expect(check.detail.contains("left-out/b.txt"), "\(check.detail)")
        #expect(plan.finding?.action.isAutomatic == false)
        #expect(!plan.isApproved)

        let result = engine.clean(worktree)
        #expect(!result.ok)
        #expect(FileManager.default.fileExists(atPath: worktree + "/kept/a.txt"))
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
    /// No git command Midden runs can reach another machine, even when the
    /// repository's own config allows the protocol.
    @Test func gitNeverContactsAnotherMachine() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let clone = home.path("clone")
        try sh(["git", "clone", "-q", repository, clone])
        try sh(["git", "-C", clone, "config", "protocol.file.allow", "always"])

        let fetch = Command.run(["git", "-C", clone, "fetch", "-q", "origin"], environment: Command.quietGit)
        #expect(!fetch.succeeded)
        #expect(fetch.message.contains("not allowed"), "\(fetch.message)")
    }

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
