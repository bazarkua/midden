import Foundation
import Synchronization
import Testing
@testable import MiddenCore

// The "not in use" check reads every process of the user. A read that
// fails because a process is exiting, or fails once while it starts a new
// program, mustn't make the whole listing incomplete; a process that stays
// unreadable must.

@Suite struct ProcessUsageTests {
    private func entry(_ pid: Int32) -> ProcessDirectories.Entry {
        ProcessDirectories.Entry(pid: pid, uid: 501, command: "tool\(pid)")
    }

    @Test func retriesAndSkipsExitingProcesses() {
        // pid 1 reads at once; pid 2 fails twice, then reads; pid 3 never
        // reads but is exiting; pid 4 is another user's.
        let failures = Mutex<[Int32: Int]>([:])
        let usage = ProcessUsage.collect(
            [entry(1), entry(2), entry(3), ProcessDirectories.Entry(pid: 4, uid: 502, command: "x")], user: 501,
            workingDirectory: { _ in .success("/") },
            executable: { .success("/bin/tool\($0)") },
            arguments: { pid in
                if pid == 3 { return nil }
                if pid == 2 {
                    let seen = failures.withLock { counts -> Int in
                        counts[pid, default: 0] += 1
                        return counts[pid]!
                    }
                    if seen < 3 { return nil }
                }
                return ["tool"]
            },
            isExiting: { $0 == 3 })
        #expect(usage.failure == nil)
        #expect(usage.processes.map(\.pid) == [1, 2])
    }

    @Test func aProcessThatStaysUnreadableMakesTheListingIncomplete() {
        var paused = 0
        let usage = ProcessUsage.collect(
            [entry(1), entry(7)], user: 501,
            workingDirectory: { _ in .success("/") },
            executable: { pid in pid == 7 ? .failure(POSIXError(.EPERM)) : .success("/bin/tool") },
            arguments: { _ in ["tool"] },
            isExiting: { _ in false },
            attempts: 3, pause: { paused += 1 })
        #expect(usage.failure?.contains("pid 7") == true)
        #expect(paused == 2)
        #expect(usage.processes.map(\.pid) == [1])
    }

    @Test func readsThisProcess() throws {
        let usage = ProcessUsage.current()
        let me = try #require(usage.processes.first { $0.pid == getpid() })
        #expect(!me.executable.isEmpty)
        #expect(!me.arguments.isEmpty)
        #expect(ProcessUsage.isExiting(getpid()) == false)
    }
}
