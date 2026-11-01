import Foundation
import Testing
@testable import MiddenCore

@Suite struct SandboxTests {
    /// A fake developer folder with an executable usr/bin/git.
    private func developerFolder(_ dir: TempDir, _ name: String) throws -> String {
        let git = try dir.write("\(name)/usr/bin/git", text: "#!/bin/sh\n")
        chmod(git, 0o755)
        return dir.path(name)
    }

    @Test func resolvesGitByItsRealPathInTheSandbox() throws {
        let dir = try TempDir()
        let xcode = try developerFolder(dir, "Xcode.app/Contents/Developer")
        let tools = try developerFolder(dir, "CommandLineTools")
        let link = dir.path("xcode_select_link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: xcode)

        // The selected developer folder wins, then the Command Line Tools.
        #expect(Command.git(sandboxed: true, xcodeSelectLink: link, commandLineTools: tools)
            == xcode + "/usr/bin/git")
        #expect(Command.git(sandboxed: true, xcodeSelectLink: dir.path("missing"), commandLineTools: tools)
            == tools + "/usr/bin/git")
        #expect(Command.git(
            sandboxed: true, xcodeSelectLink: dir.path("missing"), commandLineTools: dir.path("none")) == nil)
        // Never the /usr/bin stub, which can't run in the sandbox.
        #expect(Command.git(sandboxed: true) != "/usr/bin/git")
    }

    @Test func withoutGitWorktreesAreInfo() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        _ = try addWorktree(home, repository: repository, branch: "feature")
        guard case .directory(.worktree(let match)?, _) = try reclassify(home, "worktrees/feature") else {
            Issue.record("not a worktree")
            return
        }
        let auditor = WorktreeAuditor(git: nil, processes: ProcessDirectories(processes: []))
        let result = auditor.audit(match)
        #expect(result.safety == .info)
        #expect(result.checks.first?.passed == false)
        guard case .manual(let instructions) = result.action else {
            Issue.record("must not be removable without git")
            return
        }
        #expect(instructions.contains("Install Xcode or the Command Line Tools to check worktrees"))
    }

    @Test func simulatorCleanupIsOffInTheSandbox() throws {
        let home = try TempDir("home")
        try home.mkdir("Library/Developer/CoreSimulator/Devices")
        #expect(Simulators.unavailable(home: home.path, sandboxed: true) == nil)

        var engine = try CleanEngine(home: home.url)
        engine.sandboxed = true
        let plan = engine.plan("sim:\(UUID().uuidString)")
        #expect(!plan.isApproved)
        #expect(plan.refusal?.contains("App Store version") == true)
    }
}
