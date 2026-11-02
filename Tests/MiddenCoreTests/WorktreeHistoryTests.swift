import Foundation
import Testing
@testable import MiddenCore

private func audit(_ home: TempDir, _ path: String, now: Date = Date()) throws -> WorktreeAudit {
    let relative = String(path.dropFirst(home.path.count + 1))
    guard case .directory(.worktree(let match)?, _) = try reclassify(home, relative) else {
        throw ShellError(command: "not a worktree: \(path)", status: 1)
    }
    return WorktreeAuditor(processes: ProcessDirectories(processes: []), now: now, activeWindow: 0).audit(match)
}

private func check(_ audit: WorktreeAudit, _ id: String) -> SafetyCheck? {
    audit.checks.first { $0.id == id }
}

/// Commits a new file in the worktree and returns the commit's id.
@discardableResult
private func commit(_ home: TempDir, _ worktree: String, _ name: String) throws -> String {
    try home.write(String(worktree.dropFirst(home.path.count + 1)) + "/" + name, text: name + "\n")
    try sh(["git", "-C", worktree, "add", name])
    try sh(["git", "-C", worktree, "commit", "-q", "-m", "Add \(name)"])
    return try sh(["git", "-C", worktree, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The cases of a safety audit that decide whether removing a worktree
/// can lose commits.
@Suite struct WorktreeHistoryTests {
    // MARK: Commits only the worktree remembers

    /// A commit made on a detached HEAD, then a switch back to a clean
    /// branch. Only the worktree's HEAD reflog keeps the commit, and
    /// removing the worktree deletes that reflog.
    @Test func aCommitOnlyItsReflogKeepsBlocksRemoval() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "switch", "-q", "--detach"])
        let lost = try commit(home, worktree, "detached.txt")
        try sh(["git", "-C", worktree, "switch", "-q", "feature"])

        let result = try audit(home, worktree)
        let history = try #require(check(result, "privateHistory"))
        #expect(!history.passed)
        #expect(history.detail.contains("1 commit (\(lost.prefix(12))) isn't"), "\(history.detail)")
        #expect(result.safety == .info)
        #expect(!result.action.isAutomatic)
        // Everything else passes: the branch is clean and in origin/main.
        #expect(result.checks.filter { !$0.passed }.map(\.id) == ["privateHistory"])

        let results = await testCleaner(home).clean([worktree]).results
        #expect(results.allSatisfy { !$0.ok }, "\(results)")
        #expect(FileManager.default.fileExists(atPath: worktree))
        let reachable = try sh(["git", "-C", repository, "rev-list", "--all", "--reflog"])
        #expect(reachable.contains(lost))
    }

    /// Commits reset away on the worktree's branch stay in the
    /// branch's reflog, which lives in the repository, not the worktree.
    @Test func commitsResetAwayOnItsBranchStayInTheRepository() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try commit(home, worktree, "dropped.txt")
        try sh(["git", "-C", worktree, "reset", "-q", "--hard", "main"])

        let result = try audit(home, worktree)
        #expect(check(result, "privateHistory")?.passed == true)
        #expect(result.safety == .safe, "\(result.checks)")
    }

    /// Refs under refs/worktree are the worktree's own and go with it.
    @Test func refsOnlyTheWorktreeKeepsBlockRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "update-ref", "refs/worktree/saved", "HEAD"])

        let result = try audit(home, worktree)
        let history = try #require(check(result, "privateHistory"))
        #expect(!history.passed)
        #expect(history.detail.contains("refs/worktree/saved"), "\(history.detail)")
        #expect(result.safety == .info)
    }

    // MARK: Work that isn't in origin

    /// A branch never pushed or merged. Removal
    /// keeps the branch, but nothing outside this Mac holds the work, so
    /// it's Review with the reason.
    @Test func workOnlyOnALocalBranchIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "agent")
        try commit(home, worktree, "one.txt")
        try commit(home, worktree, "two.txt")

        let result = try audit(home, worktree)
        let integrated = try #require(check(result, "integrated"))
        #expect(!integrated.passed)
        #expect(integrated.detail.contains("agent has 2 commits that aren't in origin/main"), "\(integrated.detail)")
        #expect(integrated.detail.contains("nothing outside this Mac may hold them"), "\(integrated.detail)")
        #expect(result.safety == .review)
        #expect(result.integratedBase == nil)
        let finding = Findings.worktree(
            WorktreeMatch(path: worktree, gitDir: ""), audit: result, home: home.path, bytes: 0)
        #expect(finding.explanation.contains("couldn't confirm the commits are stored anywhere else"))
    }

    /// Pushed to a branch of origin, but not in origin/main.
    /// Being on origin isn't being merged.
    @Test func pushedButNotMergedIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "agent")
        try commit(home, worktree, "one.txt")
        try sh(["git", "-C", repository, "update-ref", "refs/remotes/origin/agent", "agent"])

        let result = try audit(home, worktree)
        let detail = check(result, "integrated")?.detail ?? ""
        #expect(detail.contains("It is on origin/agent, so it was pushed"), "\(detail)")
        #expect(result.safety == .review)
    }

    /// A repository with no remote at all.
    @Test func noRemoteIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree)
        #expect(check(result, "integrated")?.detail.contains("no remote named origin") == true)
        #expect(result.safety == .review)
    }

    /// An origin that's a folder on this Mac, written directly or reached
    /// through an insteadOf rewrite, proves nothing about another machine.
    @Test(arguments: ["/Volumes/backup/repo.git", "file:///tmp/repo.git", "../repo", "https://example.com/repo.git"])
    func originOnThisMacIsReview(url: String) throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        try sh(["git", "-C", repository, "config", "remote.origin.url", url])
        if url.hasPrefix("https://") {
            try sh(["git", "-C", repository, "config", "url./Volumes/mirror/.insteadOf", "https://example.com/"])
        }
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree)
        #expect(check(result, "integrated")?.detail.contains("origin is a folder on this Mac") == true, "\(url)")
        #expect(result.safety == .review)
    }

    /// A worktree's own configuration can name another folder as its work
    /// tree. `git worktree remove` still deletes this folder, so this one is
    /// what Midden checks.
    @Test func aWorkTreeNamedInTheWorktreesConfigDoesntMoveTheCheck() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let decoy = try addWorktree(home, repository: repository, branch: "decoy")
        try sh(["git", "-C", repository, "config", "extensions.worktreeConfig", "true"])
        try sh(["git", "-C", worktree, "config", "--worktree", "core.worktree", decoy])
        try home.write("worktrees/feature/notes.txt", text: "only here\n")
        // Without the work tree given, git itself looks at the decoy.
        #expect(try sh(["git", "-C", worktree, "status", "--porcelain"]).isEmpty)

        let result = try audit(home, worktree)
        #expect(check(result, "uncommitted")?.passed == false, "\(result.checks)")
        #expect(result.safety == .info)
    }

    @Test func unknownMainBranchIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        try sh(["git", "-C", repository, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree)
        #expect(check(result, "integrated")?.detail.contains("origin/HEAD isn't set on this Mac") == true)
        #expect(result.safety == .review)
    }

    /// origin/main last updated 40 days before "now": too old to count.
    @Test func staleMainBranchIsReview() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree, now: Date().addingTimeInterval(40 * 86_400))
        let detail = check(result, "integrated")?.detail ?? ""
        #expect(detail.contains("origin/main was last updated on this Mac 40 days ago"), "\(detail)")
        #expect(result.safety == .review)
    }

    @Test func recognizesURLsOfOtherMachines() {
        for url in ["https://github.com/a/b.git", "git@github.com:a/b.git", "ssh://git@host/x.git", "host:x"] {
            #expect(!WorktreeGitConfig.isLocal(url), "\(url)")
        }
        for url in ["file:///tmp/x", "/tmp/x", "../x", "x", "./a:b", "ext::sh -c x", ""] {
            #expect(WorktreeGitConfig.isLocal(url), "\(url)")
        }
        let config = WorktreeGitConfig.parse(
            "remote.origin.url\nhttps://example.com/a.git\0remote.origin.url\n/second\0"
                + "url./mirror/.insteadof\nhttps://example.com/\0filter.lfs.clean\ngit-lfs clean -- %f\0"
                + "filter.off.smudge\n\0remote.cache.promisor\0")
        #expect(config.originURL == "https://example.com/a.git")
        #expect(config.rewritten("https://example.com/a.git") == "/mirror/a.git")
        #expect(config.filters == ["lfs"])
        #expect(config.partialClone)
    }

    // MARK: History git can check

    /// A shallow clone doesn't have the history to check.
    @Test func shallowCloneIsReview() throws {
        let home = try TempDir("home")
        let source = try makeRepository(home, "source")
        try home.write("source/second.txt", text: "2\n")
        try sh(["git", "-C", source, "add", "."])
        try sh(["git", "-C", source, "commit", "-q", "-m", "Second"])
        let repository = home.path("repo")
        try sh(["git", "clone", "-q", "--depth", "1", "file://" + source, repository])
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree)
        #expect(check(result, "historyComplete")?.detail.contains("shallow clone") == true)
        #expect(result.safety == .review)
    }

    // MARK: Programs and network

    /// A clean filter from the repository's config is a program. git
    /// status runs it when a tracked file's timestamp changes, and `git
    /// worktree remove` runs git status. Midden runs it neither when
    /// checking nor when removing, and says the files go through a filter.
    @Test func filterProgramsNeverRun() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let marker = home.path("filter-ran")
        let spy = try home.write("spy.sh", text: "#!/bin/sh\necho ran >> '\(marker)'\ncat\n")
        chmod(spy, 0o755)
        try sh(["git", "-C", repository, "config", "filter.spy.clean", spy])
        try home.write("repo/.gitattributes", text: "*.dat filter=spy\n")
        try home.write("repo/data.dat", text: "payload\n")
        try sh(["git", "-C", repository, "add", "."])
        try sh(["git", "-C", repository, "commit", "-q", "-m", "Data"])
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.touch("worktrees/feature/data.dat", daysAgo: 1)
        try? FileManager.default.removeItem(atPath: marker)
        // What plain git does with it: the filter runs.
        _ = try sh(["git", "-C", worktree, "status", "--porcelain"])
        #expect(FileManager.default.fileExists(atPath: marker))
        try FileManager.default.removeItem(atPath: marker)
        try home.touch("worktrees/feature/data.dat", daysAgo: 2)

        let result = try audit(home, worktree)
        #expect(!FileManager.default.fileExists(atPath: marker), "the filter ran during the audit")
        let filters = try #require(check(result, "filters"))
        #expect(!filters.passed)
        #expect(filters.detail.contains("the git filter “spy” (data.dat)"), "\(filters.detail)")
        #expect(result.safety == .review)

        let results = await testCleaner(home).clean([worktree]).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(!FileManager.default.fileExists(atPath: marker), "the filter ran during the removal")
    }

    /// The filter lookup uses pathspec magic, which an inherited
    /// GIT_LITERAL_PATHSPECS=1 would turn off, finding no filtered file.
    @Test func inheritedPathspecSettingsDontHideFilteredFiles() {
        let environment = Command.environment(
            inherited: ["GIT_LITERAL_PATHSPECS": "1", "GIT_ICASE_PATHSPECS": "1"], overrides: [:],
            extra: Command.gitEnvironment(neutralizing: ["spy"]))
        #expect(environment["GIT_LITERAL_PATHSPECS"] == "0")
        #expect(environment["GIT_ICASE_PATHSPECS"] == "0")
    }

    /// A filter marked required makes git fail rather than skip it, so the
    /// check fails and the worktree isn't removable.
    @Test func aRequiredFilterStopsTheCheck() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try sh(["git", "-C", repository, "config", "filter.spy.clean", "cat"])
        try sh(["git", "-C", repository, "config", "filter.spy.smudge", "cat"])
        try sh(["git", "-C", repository, "config", "filter.spy.required", "true"])
        try home.write("repo/.gitattributes", text: "*.dat filter=spy\n")
        try home.write("repo/data.dat", text: "payload\n")
        try sh(["git", "-C", repository, "add", "."])
        try sh(["git", "-C", repository, "commit", "-q", "-m", "Data"])
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.touch("worktrees/feature/data.dat", daysAgo: 1)

        let result = try audit(home, worktree)
        #expect(check(result, "uncommitted")?.passed == false)
        #expect(result.safety == .info)
    }

    // MARK: Programs using it

    /// A program working elsewhere that names a file in the worktree, such
    /// as `tail -f <worktree>/log`, uses it too. git's file watcher doesn't.
    @Test func aProgramNamingItsFilesFromElsewhereBlocksRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        guard case .directory(.worktree(let match)?, _) = try reclassify(home, "worktrees/feature") else {
            Issue.record("not a worktree")
            return
        }
        func audit(_ processes: [ProcessUsage.Process]) -> WorktreeAudit {
            WorktreeAuditor(
                processes: ProcessDirectories(processes: []), usage: ProcessUsage(processes: processes),
                activeWindow: 0
            ).audit(match)
        }
        let tail = ProcessUsage.Process(
            pid: 4242, command: "tail", directory: "/", executable: "/usr/bin/tail",
            arguments: ["tail", "-f", worktree + "/server.log"])
        let watcher = ProcessUsage.Process(
            pid: 4243, command: "git", directory: worktree, executable: "/usr/bin/git",
            arguments: ["git", "fsmonitor--daemon", "run", "--detach"])

        let used = audit([tail, watcher])
        #expect(check(used, "inUse")?.detail == "In use by tail (pid 4242).", "\(used.checks)")
        #expect(used.safety == .info)

        let idle = audit([watcher])
        #expect(check(idle, "inUse")?.passed == true)
        #expect(check(idle, "inUse")?.detail.contains("None runs from it or names it in its arguments.") == true)
        #expect(idle.safety == .safe, "\(idle.checks)")

        let unknown = WorktreeAuditor(
            processes: ProcessDirectories(processes: []),
            usage: ProcessUsage(processes: [], failure: "1 process couldn't be read"), activeWindow: 0
        ).audit(match)
        #expect(check(unknown, "inUse")?.passed == false)
    }

    // MARK: Work stopped halfway

    @Test func aBisectInProgressBlocksRemoval() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", worktree, "bisect", "start"])

        let result = try audit(home, worktree)
        #expect(check(result, "operation")?.detail.contains("A bisect is in progress here.") == true)
        #expect(check(result, "uncommitted")?.passed == true)
        #expect(result.safety == .info)
    }
}
