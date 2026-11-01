import Foundation
import Synchronization
import Testing
@testable import MiddenCore

/// A scripted waitpid: returns the given answers in order, then `then`.
private final class ScriptedWait: Sendable {
    private let answers: Mutex<[(pid_t, Int32)]>
    private let fallback: (pid_t, Int32)
    private let made = Mutex(0)

    init(_ answers: [(pid_t, Int32)], then fallback: (pid_t, Int32) = (0, 0)) {
        self.answers = Mutex(answers)
        self.fallback = fallback
    }

    var calls: Int { made.withLock { $0 } }

    var wait: ChildReaper.Wait {
        { [self] _ in
            made.withLock { $0 += 1 }
            return answers.withLock { $0.isEmpty ? fallback : $0.removeFirst() }
        }
    }
}

/// Exit notifications the test delivers by hand.
private final class ManualExitEvents: Sendable {
    private let fire = Mutex<(@Sendable () -> Void)?>(nil)
    private let disarmed = Mutex(0)

    var disarmCount: Int { disarmed.withLock { $0 } }

    var events: ChildReaper.ExitEvents {
        { [self] _, queue, fired in
            fire.withLock { $0 = { queue.async(execute: fired) } }
            return { [self] in disarmed.withLock { $0 += 1 } }
        }
    }

    func deliver() { fire.withLock { $0 }?() }
}

private final class Tally: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
}

@Suite struct ChildReaperTests {
    private let fakePid: pid_t = 424_242

    /// The exit notification can come before the child is waitable, and it
    /// comes once. Handed over: not waitable. Notified: still not. A later
    /// scheduled look reaps it, with no second notification and no other
    /// command needed.
    @Test func reapsAChildThatBecomesWaitableAfterItsExitNotification() {
        let wait = ScriptedWait([(0, 0), (0, 0)], then: (424_242, 0))
        let events = ManualExitEvents()
        let reaper = ChildReaper(wait: wait.wait, exitEvents: events.events, firstRetry: 0.2, longestRetry: 0.2)
        let reaped = Tally()
        reaper.watch(fakePid) { reaped.add() }

        waitUntil { wait.calls == 1 }
        #expect(wait.calls == 1)
        events.deliver()
        waitUntil { wait.calls == 2 }
        #expect(wait.calls == 2)
        #expect(reaped.count == 0)

        waitUntil { reaped.count == 1 }
        #expect(reaped.count == 1)
        #expect(wait.calls == 3)
        #expect(events.disarmCount == 1)
    }

    /// A wait error other than ECHILD is "try again", not "gone": the slot
    /// stays taken until a later look reaps the child.
    @Test func aRecoverableWaitErrorKeepsTheSlotUntilTheReap() {
        let wait = ScriptedWait([(-1, EIO)], then: (424_242, 0))
        let reaper = ChildReaper(
            wait: wait.wait, exitEvents: ManualExitEvents().events, firstRetry: 0.3, longestRetry: 0.3)
        let children = CommandChildren(limit: 1) { pid, done in reaper.watch(pid, reaped: done) }
        #expect(children.reserve(until: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 10_000_000_000))
        children.handOver(fakePid)

        waitUntil { wait.calls == 1 }
        #expect(children.held == 1)
        #expect(children.lingering == 1)
        waitUntil { children.held == 0 }
        #expect(children.held == 0)
        #expect(children.lingering == 0)
        #expect(wait.calls == 2)
    }

    /// Notifications and scheduled looks arriving after the reap change
    /// nothing: the completion runs once, and the looks stop.
    @Test func duplicateDeliveriesReleaseExactlyOnce() {
        let wait = ScriptedWait([(0, 0)], then: (424_242, 0))
        let events = ManualExitEvents()
        let reaper = ChildReaper(wait: wait.wait, exitEvents: events.events, firstRetry: 0.05, longestRetry: 0.05)
        let reaped = Tally()
        reaper.watch(fakePid) { reaped.add() }

        waitUntil { wait.calls == 1 }
        events.deliver()
        events.deliver()
        events.deliver()
        waitUntil { reaped.count == 1 }
        Thread.sleep(forTimeInterval: 0.4)
        events.deliver()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(reaped.count == 1)
        #expect(wait.calls == 2)
    }

    /// A real child still running when it's handed over, exiting later, is
    /// reaped through its exit notification and the looks that follow,
    /// without another command running, and leaves no zombie.
    @Test func reapsARealChildThatExitsAfterTheWatchIsArmed() throws {
        let children = CommandChildren(limit: 2) { pid, done in ChildReaper().watch(pid, reaped: done) }
        #expect(children.reserve(until: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 10_000_000_000))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("0.5"), nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, envp) == 0)
        let handedOver = Date()
        children.handOver(pid)
        #expect(children.held == 1)
        #expect(kill(pid, 0) == 0)  // Still running when the watch is armed.

        waitUntil(5) { children.held == 0 }
        #expect(children.held == 0)
        #expect(Date().timeIntervalSince(handedOver) >= 0.4)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
