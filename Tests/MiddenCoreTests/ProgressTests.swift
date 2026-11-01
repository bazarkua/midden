import Foundation
import Synchronization
import Testing
@testable import MiddenCore

private final class FakeClock: Sendable {
    private let time = Mutex(1_000.0)
    var now: Double { time.withLock { $0 } }
    func advance(_ seconds: Double) { time.withLock { $0 += seconds } }
}

private final class Collector: Sendable {
    private let events = Mutex<[ScanProgress]>([])
    var all: [ScanProgress] { events.withLock { $0 } }
    func add(_ progress: ScanProgress) { events.withLock { $0.append(progress) } }
}

@Suite struct ProgressTests {
    @Test func estimatesHonestly() throws {
        let clock = FakeClock()
        let collector = Collector()
        let estimator = ProgressEstimator(expectedBytes: 1_000, now: { clock.now }) { collector.add($0) }
        estimator.begin(.preparing)
        estimator.begin(.reading)
        // A steady 200 bytes per second: a fifth of the reading phase per second.
        for step in 1...20 {
            clock.advance(0.25)
            estimator.reading(WalkProgress(items: Int64(step), bytes: Int64(step * 50), path: "/x"))
        }
        let reading = collector.all.filter { $0.phase == .reading }
        // No time left while the rate is noise, then a smoothed estimate.
        #expect(reading.prefix(7).allSatisfy { $0.secondsRemaining == nil })
        let halfway = try #require(reading[9].secondsRemaining)
        let expected = (1 - reading[9].fraction!) / (0.2 * 0.85)
        #expect(abs(halfway - expected) / expected < 0.1)
        // Reading stops short of its share until it really ends, even when
        // the expected size was too small.
        estimator.reading(WalkProgress(items: 99, bytes: 5_000, path: "/x"))
        #expect(collector.all.last!.fraction! < 0.85)

        estimator.begin(.worktrees, detail: "Checking worktrees", total: 4)
        #expect(collector.all.last!.fraction! >= 0.85)
        #expect(collector.all.last!.completed == 0)
        estimator.step(3)
        estimator.step(2)  // Steps finish out of order on several threads.
        estimator.step(4)
        let counted = collector.all.filter { $0.phase == .worktrees }
        #expect(counted.map(\.completed) == [0, 3, 3, 4])
        #expect(counted.allSatisfy { $0.total == 4 && $0.detail == "Checking worktrees" })
        estimator.begin(.finishing)
        #expect(collector.all.last!.completed == nil)

        let fractions = collector.all.compactMap(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(collector.all.last?.phase == .finishing)
    }

    @Test func barFollowsItemsAndBytesOnlyWhenAlone() {
        let clock = FakeClock()
        let collector = Collector()
        let estimator = ProgressEstimator(
            expectedBytes: 1_000, expectedItems: 100, now: { clock.now }
        ) { collector.add($0) }
        estimator.begin(.reading)
        // One huge file: bytes say 60%, items 10%. The bar follows items.
        estimator.reading(WalkProgress(items: 10, bytes: 600, path: "/x"))
        #expect(abs(collector.all.last!.fraction! - 0.1 * 0.85) < 1e-9)
        // Many small files: items say 70%.
        clock.advance(0.2)
        estimator.reading(WalkProgress(items: 70, bytes: 620, path: "/x"))
        #expect(abs(collector.all.last!.fraction! - 0.7 * 0.85) < 1e-9)

        // Without an item count to expect, bytes are all there is.
        let alone = Collector()
        let bytesOnly = ProgressEstimator(expectedBytes: 1_000) { alone.add($0) }
        bytesOnly.begin(.reading)
        bytesOnly.reading(WalkProgress(items: 10, bytes: 600, path: "/x"))
        #expect(abs(alone.all.last!.fraction! - 0.6 * 0.85) < 1e-9)
    }

    @Test func timeLeftIgnoresBurstsAndStalls() throws {
        let clock = FakeClock()
        let collector = Collector()
        let estimator = ProgressEstimator(
            expectedBytes: 1_000_000, expectedItems: 1_000_000, now: { clock.now }
        ) { collector.add($0) }
        estimator.begin(.reading)
        // Items arrive unevenly: a burst every fifth sample, stalls otherwise,
        // 1% of the reading phase per second on average. One huge file early on
        // moves the bar but must not make the rest look quick.
        var items: Int64 = 0
        for step in 1...150 {
            clock.advance(0.2)
            items += step % 5 == 0 ? 10_000 : 0
            let bytes: Int64 = step >= 10 ? 300_000 : 0
            estimator.reading(WalkProgress(items: items, bytes: bytes, path: "/x"))
        }
        let estimates = collector.all.compactMap(\.secondsRemaining)
        #expect(estimates.count > 100)
        // Between consecutive samples it never grows faster than the cap.
        for (earlier, later) in zip(estimates, estimates.dropFirst()) where later > earlier {
            #expect(later - earlier <= max(earlier * 0.1, 1) * 0.2 + 1e-6)
        }
        // And it stays close to the truth, which follows items: 1% of the
        // reading phase per second, 0.85% of the bar.
        let last = try #require(collector.all.last)
        let pace = 0.85 * 0.30  // 300,000 of 1,000,000 items after 30 s.
        let truth = (1 - pace) / 0.0085
        #expect(abs(last.secondsRemaining! - truth) / truth < 0.25)
    }

    @Test func aHugeFileRaisesTheBarGradually() throws {
        let clock = FakeClock()
        let collector = Collector()
        let estimator = ProgressEstimator(
            expectedBytes: 1_000, expectedItems: 1_000, now: { clock.now }
        ) { collector.add($0) }
        estimator.begin(.reading)
        var items: Int64 = 0
        for step in 1...80 {
            clock.advance(0.2)
            items += 5  // Steady: 2.5% of the phase per second.
            // One huge file at 2 s: bytes leap from 10% to 60% of the expected total.
            let bytes: Int64 = step < 10 ? Int64(step) * 10 : 600
            estimator.reading(WalkProgress(items: items, bytes: bytes, path: "/x"))
        }
        let fractions = collector.all.filter { $0.phase == .reading }.compactMap(\.fraction)
        #expect(fractions == fractions.sorted())
        // No leap: at most items' pace plus the 5%-per-second catch-up, per step.
        let steepest = zip(fractions, fractions.dropFirst()).map { $1 - $0 }.max() ?? 0
        #expect(steepest <= 0.85 * (0.005 + 0.05 * 0.2) + 1e-9)
        // But bytes are not ignored: the bar ends up where they say.
        #expect(abs(fractions.last! - 0.85 * 0.6) < 1e-9)
    }

    @Test func scanReportsPhasesInOrder() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 2_000_000)
        let repository = try makeRepository(home)
        _ = try addWorktree(home, repository: repository, branch: "task")
        try home.write("worktrees/task/node_modules/dep/index.js", bytes: 2_000_000)

        let collector = Collector()
        var options = ScanOptions(home: home.url, minimumBytes: 1_000_000)
        options.expectedBytes = 10_000_000
        _ = try await Scanner(options: options).scan { collector.add($0) }

        let events = collector.all
        let order: [ScanPhase] = [.preparing, .reading, .worktrees, .simulators, .finishing]
        let phases = events.map { order.firstIndex(of: $0.phase)! }
        #expect(phases == phases.sorted())
        #expect(events.first?.phase == .preparing)
        #expect(events.last?.phase == .finishing)
        let worktreePhase = events.filter { $0.phase == .worktrees }
        #expect(worktreePhase.allSatisfy { $0.detail == "Checking worktrees" && $0.total == 1 })
        #expect(worktreePhase.last?.completed == 1)
        #expect(events.filter { $0.phase != .worktrees }.allSatisfy { $0.completed == nil && $0.total == nil })
        let fractions = events.compactMap(\.fraction)
        #expect(fractions.count == events.count)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { $0 < 1 })
    }
}
