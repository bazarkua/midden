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
        #expect(check(result, "integrated")?.detail.contains("is a folder on this Mac") == true, "\(url)")
        #expect(result.safety == .review)
    }

    /// A push to a folder on this Mac moves origin/main as a fetch would,
    /// so a push address there proves nothing either.
    @Test(arguments: ["pushurl", "pushInsteadOf"])
    func pushingToAFolderOnThisMacIsReview(kind: String) throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        if kind == "pushurl" {
            try sh(["git", "-C", repository, "config", "remote.origin.pushurl", "/Volumes/backup/repo.git"])
        } else {
            try sh(["git", "-C", repository, "config", "url./Volumes/backup/.pushInsteadOf", "https://example.com/"])
        }
        let worktree = try addWorktree(home, repository: repository, branch: "feature")

        let result = try audit(home, worktree)
        let detail = check(result, "integrated")?.detail ?? ""
        #expect(detail.contains("or where git pushes to it, is a folder on this Mac"), "\(kind): \(detail)")
        #expect(result.safety == .review)
    }

    /// Push addresses on another machine change nothing.
    @Test func pushAddressesOfOtherMachinesStaySafe() {
        let config = WorktreeGitConfig.parse(
            "remote.origin.url\nhttps://example.com/a.git\0remote.origin.pushurl\ngit@example.com:a.git\0"
                + "url./Volumes/x/.pushinsteadof\nhttps://other.example/\0")
        #expect(config.originPushURLs == ["git@example.com:a.git"])
        #expect(config.pushRewrites == [WorktreeGitConfig.Rewrite(prefix: "https://other.example/", base: "/Volumes/x/")])
        #expect(!config.originAddresses("https://example.com/a.git").contains(where: WorktreeGitConfig.isLocal))
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

    /// A name that starts with a combining mark stays its own entry, though
    /// as Characters it would merge with the space or NUL before it.
    @Test func namesStartingWithACombiningMarkAreRead() {
        let parsed = WorktreeAuditor.parseStatus(porcelainZ: "!! \u{301}notes\0?? \u{301}x\0")
        #expect(parsed.ignored == ["\u{301}notes"])
        #expect(parsed.changed == ["\u{301}x"])
        let object = String(repeating: "a", count: 40)
        let index = WorktreeAuditor.parseIndex(lsFilesSVZ: "H 100644 \(object) 0\t\u{301}f\0S 100644 \(object) 0\tg\0")
        #expect(index.map(\.path) == ["\u{301}f", "g"])
        #expect(index.map(\.tag) == ["H", "S"])
    }

    /// Approved as Safe, then given an ignored folder before the clean: the
    /// fresh check says Review, and the worktree is refused, not removed
    /// with it. Approved at Review, the same worktree goes.
    @Test func aWorktreeLessSafeThanApprovedIsRefused() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        var engine = try CleanEngine(home: home.url)
        engine.makeAuditor = { WorktreeAuditor(processes: ProcessDirectories(processes: []), activeWindow: 0) }
        engine.runningApp = { _ in nil }
        #expect(engine.plan(worktree).finding?.safety == .safe)

        try home.write("worktrees/feature/node_modules/kept.js", text: "x\n")
        let refused = engine.clean(worktree, approvedAt: .safe)
        #expect(!refused.ok)
        #expect(refused.message?.contains("it was Safe, and now it's Review") == true, "\(refused)")
        #expect(refused.message?.contains("node_modules/") == true, "\(refused)")
        #expect(FileManager.default.fileExists(atPath: worktree + "/node_modules/kept.js"))

        let removed = engine.clean(worktree, approvedAt: .review)
        #expect(removed.ok, "\(removed)")
        #expect(!FileManager.default.fileExists(atPath: worktree))
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

    // MARK: A fetch that found origin's main branch where it was

    /// A clone whose origin, `git@fakehost:origin.git`, is another machine
    /// to Midden. A stand-in for ssh serves it from a local repository, so
    /// `git fetch` writes FETCH_HEAD and the reflogs as it really does. Its
    /// origin/main reflog is emptied, as when main hasn't moved for longer
    /// than git keeps reflog lines.
    private struct FetchedClone {
        let repository: String
        let origin: String
        let ssh: String

        init(_ home: TempDir) throws {
            origin = try makeRepository(home, "origin")
            try sh(["git", "-C", origin, "branch", "dev"])
            ssh = try home.write("fake-ssh", text: "#!/bin/sh\nexec git upload-pack '\(origin)'\n")
            try sh(["chmod", "+x", ssh])
            repository = home.path("clone")
            try sh(["GIT_SSH_COMMAND=\(ssh)", "git", "clone", "-q", "git@fakehost:origin.git", repository])
            try "".write(toFile: repository + "/.git/logs/refs/remotes/origin/main", atomically: false, encoding: .utf8)
        }

        /// Adds a commit to origin's dev branch, so a fetch moves origin/dev.
        func moveDev() throws {
            try sh(["git", "-C", origin, "switch", "-q", "dev"])
            try sh(["git", "-C", origin, "commit", "-q", "--allow-empty", "-m", "Move dev"])
            try sh(["git", "-C", origin, "switch", "-q", "main"])
        }

        /// Runs git with the ssh stand-in, in `folder` (the clone by default).
        func git(_ arguments: [String], in folder: String? = nil, date: Date? = nil) throws {
            let dated = date.map { ["GIT_COMMITTER_DATE=@\(Int($0.timeIntervalSince1970)) +0000"] } ?? []
            try sh(["GIT_SSH_COMMAND=\(ssh)"] + dated + ["git", "-C", folder ?? repository] + arguments)
        }
    }

    /// A fetch that finds origin/main unchanged writes no reflog line for
    /// it. It counts as this Mac's last update of origin/main, by its
    /// FETCH_HEAD and the line it wrote for the branch it did move.
    @Test func aFetchThatFoundMainUnchangedCountsAsAnUpdate() throws {
        let home = try TempDir("home")
        let clone = try FetchedClone(home)
        let worktree = try addWorktree(home, repository: clone.repository, branch: "feature")
        let before = try audit(home, worktree)
        #expect(check(before, "integrated")?.detail.contains("can't tell when origin/main was last updated") == true,
                "\(String(describing: check(before, "integrated")))")
        #expect(before.safety == .review)

        try clone.moveDev()
        try clone.git(["fetch", "-q", "origin"])
        let after = try audit(home, worktree)
        #expect(check(after, "integrated")?.passed == true, "\(String(describing: check(after, "integrated")))")
        #expect(after.safety == .safe)
    }

    /// A fetch of another branch only writes no FETCH_HEAD line for main.
    @Test func aFetchOfAnotherBranchSaysNothingAboutMain() throws {
        let home = try TempDir("home")
        let clone = try FetchedClone(home)
        let worktree = try addWorktree(home, repository: clone.repository, branch: "feature")
        try clone.moveDev()
        try clone.git(["fetch", "-q", "origin", "dev"])
        let result = try audit(home, worktree)
        #expect(check(result, "integrated")?.detail.contains("can't tell when origin/main was last updated") == true)
        #expect(result.safety == .review)
    }

    /// FETCH_HEAD's time counts only with a fetch's reflog line beside it:
    /// a file touched, or appended to, after its fetch proves nothing new.
    /// With both 40 days old, main is too old to count.
    @Test func aFetchHeadNewerThanItsFetchIsNoRecord() throws {
        let home = try TempDir("home")
        let clone = try FetchedClone(home)
        let worktree = try addWorktree(home, repository: clone.repository, branch: "feature")
        let old = Date().addingTimeInterval(-40 * 86_400)
        try clone.moveDev()
        try clone.git(["fetch", "-q", "origin"], date: old)
        let touched = try audit(home, worktree)
        #expect(check(touched, "integrated")?.detail.contains("can't tell when origin/main was last updated") == true,
                "\(String(describing: check(touched, "integrated")))")

        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: clone.repository + "/.git/FETCH_HEAD")
        let stale = try audit(home, worktree)
        #expect(check(stale, "integrated")?.detail.contains("origin/main was last updated on this Mac 40 days ago") == true,
                "\(String(describing: check(stale, "integrated")))")
        #expect(stale.safety == .review)
    }

    /// Another remote whose URL FETCH_HEAD writes as origin's
    /// (`bob@fakehost:origin.git` against `git@fakehost:origin.git`) makes
    /// its lines impossible to tell apart, so none count.
    @Test func aRemoteWrittenLikeOriginLeavesFetchHeadOut() throws {
        let home = try TempDir("home")
        let clone = try FetchedClone(home)
        try sh(["git", "-C", clone.repository, "remote", "add", "mirror", "bob@fakehost:origin.git"])
        let worktree = try addWorktree(home, repository: clone.repository, branch: "feature")
        try clone.moveDev()
        try clone.git(["fetch", "-q", "origin"])
        #expect(try audit(home, worktree).safety == .review)
    }

    /// A fetch run in a linked worktree writes that worktree's FETCH_HEAD.
    @Test func aFetchInAnotherWorktreeCounts() throws {
        let home = try TempDir("home")
        let clone = try FetchedClone(home)
        let worktree = try addWorktree(home, repository: clone.repository, branch: "feature")
        let other = try addWorktree(home, repository: clone.repository, branch: "other")
        try clone.moveDev()
        try clone.git(["fetch", "-q", "origin"], in: other)
        #expect(FileManager.default.fileExists(atPath: clone.repository + "/.git/worktrees/other/FETCH_HEAD"))
        #expect(try audit(home, worktree).safety == .safe)
    }

    /// origin/main is fetched from the branch origin's refspecs map onto it.
    @Test func aTrackingRefMapsToTheBranchItIsFetchedFrom() {
        func source(_ specs: [String]) -> String? {
            WorktreeGitConfig.parse(specs.map { "remote.origin.fetch\n\($0)\0" }.joined())
                .sourceBranch(of: "refs/remotes/origin/main")
        }
        #expect(source(["+refs/heads/*:refs/remotes/origin/*"]) == "main")
        #expect(source(["refs/heads/*:refs/remotes/origin/*"]) == "main")
        #expect(source(["+refs/heads/trunk:refs/remotes/origin/main"]) == "trunk")
        #expect(source([]) == nil)
        #expect(source(["+refs/heads/dev:refs/remotes/origin/dev"]) == nil)
        #expect(source(["+refs/heads/*:refs/remotes/origin/*", "+refs/heads/trunk:refs/remotes/origin/main"]) == nil)
        #expect(source(["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/main"]) == nil)
        #expect(source(["+refs/tags/*:refs/remotes/origin/*"]) == nil)
    }

    /// Remote names keep their case: `ORIGIN` is another remote, whose URL
    /// FETCH_HEAD would write like origin's.
    @Test func aRemoteNamedLikeOriginInCapitalsIsAnotherRemote() {
        let config = WorktreeGitConfig.parse(
            "remote.ORIGIN.url\nbob@host:repo.git\0remote.origin.url\nalice@host:repo.git\0")
        #expect(config.originURL == "alice@host:repo.git")
        #expect(config.otherRemoteURLs == ["bob@host:repo.git"])
        #expect(config.otherRemoteShares("alice@host:repo.git"))
    }

    /// FETCH_HEAD names origin without a user name or password, a trailing
    /// slash or .git, as git 2.54 wrote it for these URLs; a local path is
    /// copied as it is.
    @Test func fetchHeadURLsAreWrittenAsGitWritesThem() {
        let cases = [
            "https://example.com/repo.git": "https://example.com/repo",
            "https://user:token@example.com/org/repo.git": "https://example.com/org/repo",
            "git@github.com:org/repo.git": "github.com:org/repo",
            "ssh://git@host/org/repo.git/": "ssh://host/org/repo",
            "ssh://user:pw@host/org/repo": "ssh://host/org/repo",
            "host:org/repo.git": "host:org/repo",
            "https://example.com/a@b/repo": "https://example.com/a@b/repo",
            "/tmp/a@host:repo.git": "/tmp/a@host:repo",
        ]
        for (url, written) in cases {
            #expect(WorktreeAuditor.fetchHeadURL(url) == written, "\(url)")
        }
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
