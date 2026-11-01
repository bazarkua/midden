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
            estimator.reading(ScanProgress(items: Int64(step), bytes: Int64(step * 50), currentPath: "/x"))
        }
        let reading = collector.all.filter { $0.phase == .reading }
        // No time left while the rate is noise, then a smoothed estimate.
        #expect(reading.prefix(7).allSatisfy { $0.secondsRemaining == nil })
        let halfway = try #require(reading[9].secondsRemaining)
        let expected = (1 - reading[9].fraction!) / (0.2 * 0.85)
        #expect(abs(halfway - expected) / expected < 0.1)
        // Reading stops short of its share until it really ends, even when
        // the expected size was too small.
        estimator.reading(ScanProgress(items: 99, bytes: 5_000, currentPath: "/x"))
        #expect(collector.all.last!.fraction! < 0.85)

        estimator.begin(.worktrees, detail: "Checking 4 worktrees")
        #expect(collector.all.last!.fraction! >= 0.85)
        estimator.step(3, of: 4)
        estimator.step(2, of: 6)  // The total grew: the bar must not go back.
        estimator.step(4, of: 4, detail: "4 of 4 worktrees")
        estimator.begin(.finishing)

        let fractions = collector.all.compactMap(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(collector.all.last?.phase == .finishing)
        #expect(collector.all.contains { $0.detail == "4 of 4 worktrees" })
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
        #expect(events.contains { $0.phase == .worktrees && $0.detail == "1 of 1 worktrees" })
        let fractions = events.compactMap(\.fraction)
        #expect(fractions.count == events.count)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { $0 < 1 })
    }
}
