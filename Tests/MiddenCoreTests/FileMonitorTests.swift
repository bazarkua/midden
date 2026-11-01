import Foundation
import Testing
@testable import MiddenCore

/// Whether the git in PATH was built with its file-system monitor daemon.
private let gitHasFileMonitor: Bool = {
    (try? sh(["git", "version", "--build-options"]))?.contains("feature: fsmonitor--daemon") ?? false
}()

@Suite struct FileMonitorTests {
    @Test(.enabled(if: gitHasFileMonitor))
    func auditingDoesNotStartGitsFileWatcher() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", repository, "config", "core.fsmonitor", "true"])
        try home.write("worktrees/feature/new.txt", text: "x")
        guard case .directory(.worktree(let match)?, _) = try reclassify(home, "worktrees/feature") else {
            Issue.record("not a worktree")
            return
        }
        _ = WorktreeAuditor(processes: ProcessDirectories(processes: [])).audit(match)
        // `status` exits non-zero when no daemon watches the worktree.
        #expect(throws: ShellError.self) {
            try sh(["git", "-C", worktree, "fsmonitor--daemon", "status"])
        }
    }
}
