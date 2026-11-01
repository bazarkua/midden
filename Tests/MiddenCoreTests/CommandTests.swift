import Foundation
import Synchronization
import Testing
@testable import MiddenCore

@Suite struct CommandTests {
    @Test func killsACommandThatHangsWithOpenPipes() {
        let start = Date()
        let result = Command.run(["/bin/sleep", "10"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        #expect(result.error.contains("Timed out"))
    }

    /// The deadline used to apply only while stdout or stderr was open; a
    /// child that closed both and kept running was waited for without limit.
    @Test func killsACommandThatClosesItsOutputAndHangs() {
        let start = Date()
        let result = Command.run(["/bin/sh", "-c", "exec >&- 2>&-; sleep 8"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        #expect(result.error.contains("Timed out"))
    }

    @Test func reportsTheExitStatusOfACommandThatClosesItsOutput() {
        let result = Command.run(["/bin/sh", "-c", "exec >&- 2>&-; sleep 0.3; exit 3"], timeout: 10)
        #expect(result.status == 3)
    }

    /// A command's own children are stopped with it: a descendant that
    /// would write a file after the timeout must not get to.
    @Test func killsTheWholeProcessGroupOnTimeout() throws {
        let dir = try TempDir()
        let sentinel = dir.path("written-after-timeout")
        let start = Date()
        let result = Command.run(["/bin/sh", "-c", "(sleep 2; touch \"$0\") & sleep 30", sentinel], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        Thread.sleep(forTimeInterval: 2.5)
        #expect(!FileManager.default.fileExists(atPath: sentinel))
    }

    /// The command exits at once, but a background child keeps its pipes
    /// open: the call returns at the deadline, unsuccessfully, and the
    /// child doesn't survive it.
    @Test func stopsAGrandchildHoldingThePipes() throws {
        let dir = try TempDir()
        let pidFile = dir.path("grandchild.pid")
        let start = Date()
        // Its own budget: the shared one could make it wait for a slot and
        // eat into its one-second deadline. (This test once failed with no
        // pid file, cause unknown; the result is reported if it does again.)
        let result = Command.run(
            ["/bin/sh", "-c", "sleep 30 & echo $! > \"$0\"", pidFile], environment: [:], timeout: 1,
            children: CommandChildren(limit: 4), waitpid: { Darwin.waitpid($0, $1, $2) })
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(!result.succeeded)
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8) else {
            Issue.record("no pid file; the command's result: \(result)")
            return
        }
        let grandchild = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Gone, or at worst a zombie on its way out: give it a moment.
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(grandchild, 0) == 0
            if alive { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(!alive, "grandchild \(grandchild) survived the timeout")
    }

    /// A child that doesn't exit even after SIGKILL (stuck in the kernel):
    /// the call must still return, unsuccessfully, a bounded time after the
    /// deadline instead of waiting for it.
    @Test func returnsWhenTheKilledChildDoesNotExit() {
        let outcome = System.withDeadline(10) {
            Command.run(["/bin/sleep", "30"], environment: [:], timeout: 1) { _, _, _ in 0 }
        }
        let result = outcome
        #expect(result != nil, "Command.run waited for a child that never exited")
        #expect(result?.status == -1)
        #expect(result?.error.contains("didn't exit") == true, "\(result?.error ?? "")")
    }

    /// waitpid interrupted again and again: the deadline and the grace
    /// period still hold on every turn of the loop.
    @Test func endlessInterruptionsDontOutlastTheDeadline() {
        let outcome = System.withDeadline(10) {
            Command.run(["/bin/sleep", "30"], environment: [:], timeout: 1) { _, _, _ in
                errno = EINTR
                return -1
            }
        }
        #expect(outcome != nil, "Command.run kept retrying an interrupted wait")
        #expect(outcome?.status == -1)
        #expect(outcome?.error.contains("Timed out") == true, "\(outcome?.error ?? "")")
    }

    /// When the exit status can't be read, the command didn't succeed.
    @Test func anUnreadableExitStatusIsAFailure() {
        let result = Command.run(["/usr/bin/true"], environment: [:], timeout: 10) { _, _, _ in
            errno = ECHILD
            return -1
        }
        #expect(result.status == -1)
        #expect(!result.succeeded)
        #expect(result.error.contains("exit status"), "\(result.error)")
    }

    @Test func capturesBothStreams() {
        let result = Command.run(["/bin/sh", "-c", "echo out; echo err >&2"])
        #expect(result.succeeded)
        #expect(result.output == "out\n")
        #expect(result.error == "err\n")
    }
}

private final class Tally: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// Runs `body` on `count` threads at once and waits for all of them.
private func concurrently(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let done = DispatchGroup()
    for index in 0..<count {
        done.enter()
        Thread {
            body(index)
            done.leave()
        }.start()
    }
    done.wait()
}

@Suite struct CommandChildrenTests {
    private let waitpid: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { Darwin.waitpid($0, $1, $2) }

    /// Two commands hold a budget of two. Four more, started at the same
    /// time with a short deadline, all wait for a slot, get none, and start
    /// nothing; the budget never goes past two; and it's free again once
    /// the first two exit.
    @Test func concurrentCommandsStayWithinATinyBudget() throws {
        let dir = try TempDir()
        let children = CommandChildren(limit: 2)
        let holders = Tally()
        Thread {
            concurrently(2) { _ in
                _ = Command.run(
                    ["/bin/sleep", "1.5"], environment: [:], timeout: 10, children: children,
                    waitpid: { Darwin.waitpid($0, $1, $2) })
                holders.add()
            }
        }.start()
        let started = Date(timeIntervalSinceNow: 5)
        while children.held < 2, Date() < started { Thread.sleep(forTimeInterval: 0.005) }
        try #require(children.held == 2)

        let refused = Tally()
        let root = dir.path
        concurrently(4) { index in
            let result = Command.run(
                ["/usr/bin/touch", root + "/ran-\(index)"], environment: [:], timeout: 0.3, children: children,
                waitpid: { Darwin.waitpid($0, $1, $2) })
            if !result.succeeded, result.error.contains("already running") { refused.add() }
        }
        #expect(refused.count == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(children.highWater == 2)

        let exited = Date(timeIntervalSinceNow: 10)
        while holders.count < 2, Date() < exited { Thread.sleep(forTimeInterval: 0.01) }
        #expect(children.held == 0)
        let after = Command.run(["/usr/bin/true"], environment: [:], timeout: 5, children: children, waitpid: waitpid)
        #expect(after.succeeded)
    }

    /// A command that can't be launched gives its slot back.
    @Test func aLaunchFailureGivesTheSlotBack() {
        let children = CommandChildren(limit: 1)
        let failed = Command.run(
            ["/nonexistent/tool"], environment: [:], timeout: 5, children: children, waitpid: waitpid)
        #expect(!failed.succeeded)
        #expect(children.held == 0)
        let next = Command.run(["/usr/bin/true"], environment: [:], timeout: 5, children: children, waitpid: waitpid)
        #expect(next.succeeded)
    }

    /// A killed command that hasn't exited keeps its slot, handed over
    /// without a gap, until it's reaped; meanwhile nothing else starts.
    @Test func aLingeringChildKeepsItsSlotUntilReaped() throws {
        let dir = try TempDir()
        let pending = Mutex<(pid: pid_t, reaped: (@Sendable () -> Void)?)>((0, nil))
        let children = CommandChildren(limit: 1) { pid, reaped in
            pending.withLock { $0 = (pid, reaped) }
        }
        // run() never sees it exit, so it hands the child over.
        let neverExits: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { _, _, _ in 0 }
        let lingering = Command.run(
            ["/bin/sleep", "30"], environment: [:], timeout: 0.2, children: children, waitpid: neverExits)
        #expect(lingering.error.contains("didn't exit"), "\(lingering.error)")
        #expect(children.held == 1)
        #expect(children.lingering == 1)

        let marker = dir.path("ran")
        let refused = Command.run(
            ["/usr/bin/touch", marker], environment: [:], timeout: 0.3, children: children, waitpid: waitpid)
        #expect(!refused.succeeded)
        #expect(!FileManager.default.fileExists(atPath: marker))

        // Reap it here, as the watch would, and report it.
        let (pid, reaped) = pending.withLock { $0 }
        var status: Int32 = 0
        #expect(Darwin.waitpid(pid, &status, 0) == pid)
        let report = try #require(reaped)
        report()
        #expect(children.held == 0)
        #expect(children.lingering == 0)
        let allowed = Command.run(
            ["/usr/bin/touch", marker], environment: [:], timeout: 5, children: children, waitpid: waitpid)
        #expect(allowed.succeeded)
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    /// An admission whose deadline has passed takes nothing, even with
    /// slots free.
    @Test func anExpiredDeadlineReservesNothing() {
        let children = CommandChildren(limit: 2)
        let past = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - 1
        #expect(!children.reserve(until: past))
        #expect(children.held == 0)
    }

    /// A command whose deadline has already passed starts nothing: it
    /// never gets to create its file.
    @Test func aCommandPastItsDeadlineLaunchesNothing() throws {
        let dir = try TempDir()
        let children = CommandChildren(limit: 4)
        for index in 0..<10 {
            let result = Command.run(
                ["/usr/bin/touch", dir.path("launched-\(index)")], environment: [:], timeout: 0,
                children: children, waitpid: waitpid)
            #expect(!result.succeeded)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(children.held == 0)
    }

    /// A command still waiting for a slot when its deadline passes gives
    /// up, and starts nothing even when a slot frees up just afterwards.
    @Test func capacityFreedAfterTheDeadlineLaunchesNothing() throws {
        let dir = try TempDir()
        let children = CommandChildren(limit: 1)
        try #require(children.reserve(until: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 60_000_000_000))
        let sentinel = dir.path("launched")
        let outcome = Mutex<CommandResult?>(nil)
        Thread {
            let result = Command.run(
                ["/usr/bin/touch", sentinel], environment: [:], timeout: 0.2, children: children,
                waitpid: { Darwin.waitpid($0, $1, $2) })
            outcome.withLock { $0 = result }
        }.start()
        Thread.sleep(forTimeInterval: 0.4)
        children.release()
        let deadline = Date(timeIntervalSinceNow: 5)
        while outcome.withLock({ $0 }) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let result = try #require(outcome.withLock { $0 })
        #expect(!result.succeeded)
        #expect(result.error.contains("already running"), "\(result.error)")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!FileManager.default.fileExists(atPath: sentinel))
        #expect(children.held == 0)
    }

    /// waitpid fails with something other than ECHILD while the child is
    /// alive: the status is unknown, but the child is still ours, so the
    /// command fails, the child is stopped, and its slot stays taken until
    /// the watch has reaped it.
    @Test func aWaitErrorOtherThanECHILDKeepsTheSlot() throws {
        let pending = Mutex<(pid: pid_t, reaped: (@Sendable () -> Void)?)>((0, nil))
        let children = CommandChildren(limit: 1) { pid, reaped in
            pending.withLock { $0 = (pid, reaped) }
        }
        let failing: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { _, _, _ in
            errno = EIO
            return -1
        }
        let result = Command.run(
            ["/bin/sleep", "30"], environment: [:], timeout: 1, children: children, waitpid: failing)
        #expect(!result.succeeded)
        #expect(result.error.contains("exit status"), "\(result.error)")
        #expect(children.held == 1)
        #expect(children.lingering == 1)

        let (pid, reaped) = pending.withLock { $0 }
        try #require(pid > 0)
        var status: Int32 = 0
        #expect(Darwin.waitpid(pid, &status, 0) == pid)  // Stopped, so it exits.
        let report = try #require(reaped)
        report()
        #expect(children.held == 0)
    }

    /// ECHILD says the process isn't this one's child any more: the slot
    /// is released at once.
    @Test func ECHILDReleasesTheSlot() {
        let children = CommandChildren(limit: 1)
        let notOurs: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { _, _, _ in
            errno = ECHILD
            return -1
        }
        let result = Command.run(
            ["/usr/bin/true"], environment: [:], timeout: 10, children: children, waitpid: notOurs)
        #expect(!result.succeeded)
        #expect(children.held == 0)
        #expect(children.lingering == 0)
    }

    /// The default watch reaps a lingering child as soon as it exits,
    /// without another command running, and leaves no zombie.
    @Test func theDefaultWatchReapsALingeringChild() throws {
        let children = CommandChildren(limit: 4)
        let child = Mutex<pid_t>(0)
        let neverExits: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { pid, _, _ in
            child.withLock { $0 = pid }
            return 0
        }
        let result = Command.run(
            ["/bin/sleep", "30"], environment: [:], timeout: 1, children: children, waitpid: neverExits)
        #expect(result.error.contains("didn't exit"), "\(result.error)")
        let pid = child.withLock { $0 }
        try #require(pid > 0)
        let deadline = Date(timeIntervalSinceNow: 5)
        while children.held > 0 || kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(children.held == 0)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
