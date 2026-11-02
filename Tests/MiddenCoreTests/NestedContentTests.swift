import Foundation
import Testing
@testable import MiddenCore

/// A git clone at `relative` in `home`, with one commit that exists only
/// there. Returns the commit's id.
@discardableResult
private func makeClone(_ home: TempDir, _ relative: String) throws -> String {
    let path = try home.mkdir(relative)
    try sh(["git", "init", "-q", "-b", "main"], in: path)
    try home.write(relative + "/patch.js", text: "local fix\n")
    try sh(["git", "add", "."], in: path)
    try sh(["git", "commit", "-q", "-m", "Local fix"], in: path)
    return try sh(["git", "rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func scanFindings(_ home: TempDir) async throws -> [String: Finding] {
    var options = ScanOptions.fakeHome(home, minimumBytes: 0)
    options.worktreeActiveWindow = 0
    let report = try await Scanner(options: options).scan()
    return Dictionary(uniqueKeysWithValues: report.findings.map { ($0.path, $0) })
}

private func nested(_ finding: Finding?) -> SafetyCheck? {
    finding?.checks.first { $0.id == "nestedContent" }
}

/// A folder Midden deletes whole can hold another repository that nothing
/// else checks: a clone in node_modules, or in an ignored folder of a
/// worktree. Deleting the folder would delete that repository's work.
@Suite struct NestedContentTests {
    @Test func aCloneInsideNodeModulesIsNeverDeleted() async throws {
        let home = try TempDir("home")
        try home.write("app/package.json", text: "{}")
        try home.write("app/node_modules/left-pad/index.js", bytes: 10_000)
        let commit = try makeClone(home, "app/node_modules/mylib")
        try home.touch("app/package.json", daysAgo: 30)

        let findings = try await scanFindings(home)
        let modules = try #require(findings[home.path("app/node_modules")])
        let check = try #require(nested(modules))
        #expect(!check.passed)
        #expect(check.detail.contains("It holds a repository Midden can't check: mylib."), "\(check.detail)")
        #expect(modules.safety == .info)
        #expect(!modules.action.isAutomatic)

        let results = await testCleaner(home).clean([home.path("app/node_modules")]).results
        #expect(results.allSatisfy { !$0.ok }, "\(results)")
        let kept = try sh(["git", "cat-file", "-t", commit], in: home.path("app/node_modules/mylib"))
        #expect(kept.contains("commit"))
    }

    /// `git worktree remove` deletes ignored folders without asking, and
    /// git status reports one as a single entry, so a clone inside one is
    /// invisible to git.
    @Test func aCloneInAnIgnoredFolderOfAWorktreeBlocksRemoval() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/.gitignore", text: "node_modules/\nvendor/\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore vendor"])
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        let commit = try makeClone(home, "worktrees/feature/vendor/tool")

        let findings = try await scanFindings(home)
        let tree = try #require(findings[worktree])
        #expect(nested(tree)?.detail.contains("vendor/tool") == true, "\(tree.checks)")
        #expect(tree.safety == .info)
        #expect(!tree.action.isAutomatic)
        #expect(tree.explanation.contains("won't remove it until the checks below pass"))

        let results = await testCleaner(home).clean([worktree]).results
        #expect(results.allSatisfy { !$0.ok }, "\(results)")
        let kept = try sh(["git", "cat-file", "-t", commit], in: home.path("worktrees/feature/vendor/tool"))
        #expect(kept.contains("commit"))
    }

    /// Package checkouts SwiftPM makes are clones too, but SwiftPM makes
    /// them again: Review, with what edits in them would cost. A Python
    /// environment is Review as well.
    @Test func checkoutsAndEnvironmentsInAWorktreeAreReview() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/.gitignore", text: ".build/\n.venv/\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore build output"])
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try makeClone(home, "worktrees/feature/.build/checkouts/swift-argument-parser")
        try home.write("worktrees/feature/.venv/pyvenv.cfg", text: "home = /usr/bin\n")

        let findings = try await scanFindings(home)
        let tree = try #require(findings[worktree])
        let detail = nested(tree)?.detail ?? ""
        #expect(detail.contains(".build/checkouts/swift-argument-parser is a package checkout"), "\(detail)")
        #expect(detail.contains("Python virtual environment (.venv)"), "\(detail)")
        #expect(tree.safety == .review)
        #expect(tree.action.isAutomatic)
    }

    /// SwiftPM's .build keeps its checkouts when cleaned, so a clone there
    /// doesn't count.
    @Test func keptCheckoutsInABuildFolderDontCount() async throws {
        let home = try TempDir("home")
        try home.write("tool/Package.swift", text: "// swift-tools-version: 6.0\n")
        try home.write("tool/.build/arm64-apple-macosx/debug/tool.o", bytes: 10_000)
        try makeClone(home, "tool/.build/checkouts/swift-argument-parser")
        try home.touch("tool/Package.swift", daysAgo: 30)

        let findings = try await scanFindings(home)
        let build = try #require(findings[home.path("tool/.build")])
        #expect(nested(build)?.passed == true, "\(build.checks)")
    }

    /// What can't be read counts as unknown, never as empty: a subfolder
    /// listed but never visited, a partial listing, or no root listing.
    @Test func unreadFoldersAreUnknownNotEmpty() {
        func entry(_ name: String, _ kind: DirectoryEntry.Kind) -> DirectoryEntry {
            DirectoryEntry(name: name, kind: kind, device: 1, inode: 1, linkCount: 1, allocatedSize: 0, modified: 0)
        }
        let recorder = NestedContent(root: "/r", isWorktree: false, device: 1)
        recorder.add(path: "/r", entries: [entry("a", .directory), entry("b", .directory)], isComplete: true)
        recorder.add(path: "/r/a", entries: [], isComplete: true)
        #expect(recorder.found.unread == 1)
        recorder.add(path: "/r/b", entries: [], isComplete: false)
        #expect(recorder.found.unread == 1)

        let unseen = NestedContent(root: "/r", isWorktree: false, device: 1)
        #expect(unseen.found.unread == 1)
        let check = NestedContent.check(unseen.found, path: "/r", action: .removeDirectory)
        #expect(!check.check.passed)
        #expect(check.safety == .review)
        #expect(NestedContent.check(nil, path: "/r", action: .removeDirectory).safety == .review)
    }
}
