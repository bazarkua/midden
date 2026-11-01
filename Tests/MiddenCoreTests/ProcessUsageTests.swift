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

    /// A relative path in an argument, alone or as a flag's value, means a
    /// path from the process's working directory.
    @Test func resolvesRelativeArgumentsFromTheWorkingDirectory() {
        let folder = "/Users/me/Library/Caches/pnpm/dlx"
        func process(_ arguments: [String], in directory: String = "/Users/me/code/app") -> ProcessUsage.Process {
            ProcessUsage.Process(pid: 9, command: "node", directory: directory, executable: "/usr/bin/node", arguments: arguments)
        }
        let using = [
            process(["node", "../../Library/Caches/pnpm/dlx/abc/node_modules/.bin/tool"]),
            process(["node", "--require=../../Library/Caches/pnpm/dlx/abc/hook.js", "index.js"]),
            process(["node", "--cache", "./x/../../../Library/Caches/pnpm/dlx"]),
            process(["pnpm", "dlx"], in: "/Users/me/Library/Caches/pnpm"),
        ]
        for candidate in using {
            #expect(!ProcessUsage(processes: [candidate]).using(folder).isEmpty, "\(candidate.arguments)")
        }
        let elsewhere = [
            process(["node", "../../Library/Caches/pnpm/dlx2/x.js"]),
            process(["node", "--require=./hook.js"]),
            process(["node", "-e", "1+1"]),
        ]
        for candidate in elsewhere {
            #expect(ProcessUsage(processes: [candidate]).using(folder).isEmpty, "\(candidate.arguments)")
        }
    }

    /// KERN_PROCARGS2 data: argc, the executable's path, padding, then
    /// argc NUL-terminated arguments. Anything short of that is unknown.
    @Test func rejectsTruncatedOrInvalidArgumentRecords() {
        func record(argc: Int32, _ body: String) -> [UInt8] {
            withUnsafeBytes(of: argc) { Array($0) } + Array(body.utf8)
        }
        let valid = record(argc: 2, "/bin/sh\0\0\0sh\0script.sh\0")
        #expect(ProcessUsage.ArgumentReader.parse(valid, size: valid.count) == ["sh", "script.sh"])
        // The last argument isn't terminated: cut off.
        let truncated = record(argc: 2, "/bin/sh\0\0sh\0script.s")
        #expect(ProcessUsage.ArgumentReader.parse(truncated, size: truncated.count) == nil)
        // Fewer arguments than argc says.
        let short = record(argc: 3, "/bin/sh\0\0sh\0script.sh\0")
        #expect(ProcessUsage.ArgumentReader.parse(short, size: short.count) == nil)
        // No executable path terminator, no arguments, or a negative count.
        let noPath = record(argc: 1, "/bin/sh")
        #expect(ProcessUsage.ArgumentReader.parse(noPath, size: noPath.count) == nil)
        let zero = record(argc: 0, "/bin/sh\0\0")
        #expect(ProcessUsage.ArgumentReader.parse(zero, size: zero.count) == nil)
        let negative = record(argc: -1, "/bin/sh\0\0sh\0")
        #expect(ProcessUsage.ArgumentReader.parse(negative, size: negative.count) == nil)
        // Only the bytes the kernel wrote count.
        #expect(ProcessUsage.ArgumentReader.parse(valid, size: valid.count - 1) == nil)
    }

    @Test func readsThisProcess() throws {
        let usage = ProcessUsage.current()
        let me = try #require(usage.processes.first { $0.pid == getpid() })
        #expect(!me.executable.isEmpty)
        #expect(!me.arguments.isEmpty)
        #expect(ProcessUsage.isExiting(getpid()) == false)
    }
}
