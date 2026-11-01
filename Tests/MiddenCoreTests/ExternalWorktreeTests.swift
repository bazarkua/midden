import Foundation
import Testing
@testable import MiddenCore

// A repository in a temporary "home" with worktrees in another temporary
// folder outside it, the way AI tools put worktrees in /private/tmp.
// Everything is deleted with the temporary folders.

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

@Suite struct ExternalWorktreeTests {
    private func scan(_ home: TempDir) async throws -> ScanReport {
        var options = ScanOptions.fakeHome(home, minimumBytes: 1_000_000)
        options.worktreeActiveWindow = 0
        return try await Scanner(options: options).scan()
    }

    @Test func scannerFindsWorktreesOutsideHome() async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        let repository = try makeRepository(home, "repo")
        let worktree = outside.path("agent-task")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "agent-task", worktree])
        try outside.write("agent-task/node_modules/dep/index.js", bytes: 2_000_000)
        // A registered worktree whose folder is gone is skipped.
        let gone = outside.path("gone")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "gone", gone])
        try FileManager.default.removeItem(atPath: gone)

        let report = try await scan(home)
        let found = try #require(report.findings.first { $0.path == worktree })
        #expect(found.category == .worktrees)
        #expect(found.group == "repo")
        #expect(found.safety == .safe)
        #expect(found.bytes >= 2_000_000)
        #expect(found.breakdown.first?.name == "node_modules")
        #expect(found.explanation.contains("outside your home folder"))
        #expect(found.action == CleanAction.run(["git", "-C", repository, "worktree", "remove", worktree]))
        #expect(!report.findings.contains { $0.path == gone })

        let discovery = ExternalWorktrees.discover(
            gitDirectories: [repository + "/.git"], home: home.path)
        #expect(discovery.worktrees.map(\.path) == [worktree])
        #expect(discovery.prunable == 1)
    }

    @Test func cleanerRemovesAProvenWorktreeOutsideHome() async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        let repository = try makeRepository(home, "repo")
        let worktree = outside.path("agent-task")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "agent-task", worktree])

        let summary = await Cleaner(home: home.url).clean([worktree])
        #expect(summary.results.first?.ok == true, "\(summary.results)")
        #expect(!exists(worktree))
        #expect(try sh(["git", "-C", repository, "branch", "--list", "agent-task"]).contains("agent-task"))
    }

    @Test func refusesWhatItCannotProve() async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        let elsewhere = try TempDir("elsewhere")
        let repository = try makeRepository(home, "repo")
        let real = outside.path("real")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "real", real])

        // Points into the repository, but the repository lists `real` there.
        try outside.write("forged/.git", text: "gitdir: \(repository)/.git/worktrees/real\n")
        try outside.write("forged/precious.txt", text: "keep me")
        // A real worktree, but of a repository outside home.
        let foreign = try makeRepository(elsewhere, "foreign")
        let foreignWorktree = outside.path("foreign-task")
        try sh(["git", "-C", foreign, "worktree", "add", "-q", "-b", "task", foreignWorktree])
        // An ordinary folder, and a symlink to the real worktree.
        try outside.write("plain/file.txt", text: "hello")
        try FileManager.default.createSymbolicLink(atPath: outside.path("alias"), withDestinationPath: real)
        // A submodule-style .git file.
        try outside.write("module/.git", text: "gitdir: \(repository)/.git/modules/lib\n")

        let refused: [String: String] = [
            outside.path("forged"): "lists a different folder",
            foreignWorktree: "repository isn't inside your home folder",
            outside.path("plain"): "isn't a linked git worktree",
            outside.path("alias"): "isn't canonical",
            outside.path("module"): "doesn't point into a repository's .git/worktrees",
            (home.path as NSString).deletingLastPathComponent: "contains your home folder",
        ]
        let summary = await Cleaner(home: home.url).clean(Array(refused.keys))
        for result in summary.results {
            #expect(!result.ok, "\(result.id)")
            let expected = refused[result.id] ?? "?"
            #expect(result.message?.contains(expected) == true, "\(result.id): \(result.message ?? "")")
            #expect(result.message?.contains("outside your home folder") == true)
        }
        #expect(exists(outside.path("forged/precious.txt")))
        #expect(exists(foreignWorktree))
        #expect(exists(real))
        #expect(exists(outside.path("plain/file.txt")))

        // The proven one is accepted.
        guard case .success(let match) = ExternalWorktrees.verify(real, home: home.path) else {
            Issue.record("the real worktree wasn't proven")
            return
        }
        #expect(match.gitDir == repository + "/.git/worktrees/real")
    }

    @Test func namesTheToolThatMadeAWorktree() throws {
        let home = "/Users/me"
        let cases: [(String, String?)] = [
            ("/Users/me/Work/app/.claude/worktrees/agent-a1b2", "Claude Code"),
            ("/private/tmp/claude-501/-Users-me-Work-app/0f1e/scratchpad/wt", "Claude Code"),
            ("/Users/me/.codex/worktrees/3f2a/app", "Codex"),
            ("/private/tmp/codex-l4-final-dev", "Codex"),
            ("/Users/me/.cursor/worktrees/app/GxSol", "Cursor"),
            ("/Users/me/Work/app-feature", nil),
            ("/private/tmp/claudeish", nil),
            ("/Users/other/.codex/worktrees/x/app", nil),
        ]
        for (path, tool) in cases {
            #expect(WorktreeCreator.identify(path, home: home)?.tool == tool, "\(path)")
        }
        let codex = try #require(WorktreeCreator.identify("/private/tmp/codex-l4-final-dev", home: home))
        #expect(codex.evidence.contains("codex-l4-final-dev"))
        let claude = try #require(WorktreeCreator.identify(
            "/private/tmp/claude-501/-Users-me-Work-app/0f1e/scratchpad/wt", home: home))
        #expect(claude.evidence.contains("/private/tmp/claude-501"))
    }

    @Test func findsCodexWorktreesNextToItsHistory() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home, "Work/app")
        let worktree = home.path(".codex/worktrees/3f2a/app")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "codex/task", worktree])
        try home.write(".codex/worktrees/3f2a/app/node_modules/dep/index.js", bytes: 2_000_000)
        try home.write(".codex/sessions/2026/10/31/rollout.jsonl", bytes: 1_500_000)

        let report = try await scan(home)
        let found = try #require(report.findings.first { $0.path == worktree })
        #expect(found.title == "Codex worktree app (codex/task)")
        #expect(found.group == "app")
        let history = try #require(report.findings.first { $0.path == home.path(".codex/sessions") })
        #expect(history.category == .personal)
        #expect(!history.action.isAutomatic)
    }

    @Test func titlesAClaudeCodeWorktree() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home, "repo")
        let worktree = home.path("repo/.claude/worktrees/agent-a1b2")
        try sh(["git", "-C", repository, "worktree", "add", "-q", "-b", "fix-login", worktree])
        try home.write("repo/.claude/worktrees/agent-a1b2/node_modules/dep/index.js", bytes: 2_000_000)

        let report = try await scan(home)
        let found = try #require(report.findings.first { $0.path == worktree })
        #expect(found.title == "Claude Code worktree agent-a1b2 (fix-login)")
        #expect(found.group == "repo")
        #expect(found.explanation.contains("that Claude Code made for a parallel task"))
        #expect(!found.explanation.contains("outside your home folder"))
    }
}
