import Foundation
import Testing
@testable import MiddenCore

/// Whether the git in PATH was built with its file-system monitor daemon.
private let gitHasFileMonitor: Bool = {
    (try? sh(["git", "version", "--build-options"]))?.contains("feature: fsmonitor--daemon") ?? false
}()

/// git fsmonitor--daemon processes of this user.
private func fileMonitorPIDs() -> Set<Int32> {
    guard case .success(let entries) = ProcessDirectories.listProcesses() else { return [] }
    return Set(entries.filter {
        $0.uid == getuid() && $0.command == "git"
            && (ProcessDirectories.processArguments($0.pid)?.contains("fsmonitor--daemon") ?? false)
    }.map(\.pid))
}

private func isRunning(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

@Suite struct FileMonitorTests {
    @Test func gitFileWatcherIsNotAProgramUsingTheWorktree() throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try publish(repository)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        guard case .directory(.worktree(let match)?, _) = try reclassify(home, "worktrees/feature") else {
            Issue.record("not a worktree")
            return
        }
        let entries = [
            ProcessDirectories.Entry(pid: 10, uid: 501, command: "git"),
            ProcessDirectories.Entry(pid: 11, uid: 501, command: "git"),
            ProcessDirectories.Entry(pid: 12, uid: 501, command: "node"),
        ]
        let arguments: [Int32: [String]] = [
            10: ["git", "fsmonitor--daemon", "run", "--detach", "--ipc-threads=8"],
            11: ["git", "rebase", "-i", "main"],
            12: ["node", "fsmonitor--daemon"],  // Not git: still a program in use.
        ]
        func audit(_ pids: Set<Int32>) -> WorktreeAudit {
            let processes = ProcessDirectories.collect(
                entries.filter { pids.contains($0.pid) }, user: 501,
                workingDirectory: { _ in .success(worktree + "/src") }, arguments: { arguments[$0] })
            return WorktreeAuditor(processes: processes, activeWindow: 0).audit(match)
        }

        let watched = audit([10])
        #expect(watched.safety == .safe)
        let inUse = try #require(watched.checks.first { $0.id == "inUse" })
        #expect(inUse.passed)
        #expect(inUse.detail.contains("git's file watcher is running here; Midden stops it before removing"))

        let rebasing = audit([10, 11])
        #expect(rebasing.safety == .info)
        let busy = try #require(rebasing.checks.first { $0.id == "inUse" })
        #expect(!busy.passed)
        #expect(busy.detail == "In use by git (pid 11).")

        #expect(audit([12]).safety == .info)
    }

    @Test func readsProcessArguments() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { sleeper.terminate() }
        #expect(ProcessDirectories.processArguments(sleeper.processIdentifier) == ["/bin/sleep", "60"])
        #expect(ProcessDirectories.processArguments(-1) == nil)
    }

    @Test(.enabled(if: gitHasFileMonitor))
    func worktreeWithGitFileWatcherIsStillRemovable() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try sh(["git", "-C", repository, "config", "core.fsmonitor", "true"])

        let before = fileMonitorPIDs()
        try sh(["git", "-C", worktree, "fsmonitor--daemon", "start"])
        defer { _ = try? sh(["git", "-C", worktree, "fsmonitor--daemon", "stop"]) }
        #expect(try sh(["git", "-C", worktree, "fsmonitor--daemon", "status"]).contains("watching"))
        // Daemons that appeared meanwhile: ours, and any other repository's
        // that happened to start on this Mac at the same moment.
        let started = fileMonitorPIDs().subtracting(before)
        #expect(!started.isEmpty)

        let summary = await Cleaner(home: home.url).clean([worktree])
        #expect(summary.results.first?.ok == true, "\(summary.results)")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(try sh(["git", "-C", repository, "branch", "--list", "feature"]).contains("feature"))

        // The cleaner stopped the daemon before removing the worktree.
        let deadline = Date(timeIntervalSinceNow: 10)
        while started.allSatisfy(isRunning), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(started.contains { !isRunning($0) })
    }

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
