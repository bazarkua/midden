import Foundation
import Synchronization

/// Turns raw scan events into the progress the app shows: a phase, an
/// overall fraction and, once it means something, an estimate of the time
/// left.
///
/// How the estimate is made, and why it can be trusted not to lie:
///
/// - Phases have fixed shares of the bar. Reading the folders is 85%,
///   checking worktrees 12%, simulators 1% and building the report 2%.
///   Reading is most of a scan: about 70% of the time on a Mac with 69
///   worktrees (20 GB of them outside home to size), and nearly all of it
///   with few worktrees. The time-left estimate follows the real pace, so
///   a slower worktree phase shows up there rather than as a stuck bar.
/// - Reading progress is bytes counted so far over the bytes expected. The
///   app passes the previous scan's total when it has one. Otherwise the
///   denominator is the volume's used space (total minus free), which can
///   only overestimate the home folder: the bar under-promises and jumps
///   ahead when reading ends, instead of sitting at 99% while work remains.
///   Within a phase the fraction is capped at 99% of its share until the
///   phase really ends, because a stale expected size may be too small.
/// - The worktree phase advances one step per worktree: sized if it's
///   outside home, then audited.
/// - The published fraction never goes backwards (it's the running maximum)
///   and stays below 1: the report itself is the 100%.
/// - Time left comes from how fast the fraction moves: an exponential
///   moving average of its rate, sampled at most every 200 ms with weight
///   0.2 for the newest sample, so one fast or slow folder doesn't swing
///   it. It's withheld for the first 2 seconds, while the rate is noise,
///   and whenever the average rate isn't positive.
final class ProgressEstimator: Sendable {
    /// Share of the bar where each phase starts, and its width.
    static let shares: [ScanPhase: (start: Double, width: Double)] = [
        .preparing: (0, 0),
        .reading: (0, 0.85),
        .worktrees: (0.85, 0.12),
        .simulators: (0.97, 0.01),
        .finishing: (0.98, 0.01),
    ]
    static let warmUp: TimeInterval = 2
    static let sampleInterval: TimeInterval = 0.2
    static let smoothing = 0.2

    private struct State {
        var phase: ScanPhase = .preparing
        /// Progress within the phase, 0...1.
        var phaseFraction = 0.0
        var items: Int64 = 0
        var bytes: Int64 = 0
        var path = ""
        var detail: String?
        var completed: Int?
        var total: Int?
        var published = 0.0
        var sampleTime: TimeInterval?
        var sampleFraction = 0.0
        var rate: Double?
    }

    private let state = Mutex(State())
    private let expectedBytes: Int64
    private let started: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let report: @Sendable (ScanProgress) -> Void

    /// - Parameters:
    ///   - expectedBytes: the previous scan's total, or an upper bound.
    ///   - now: seconds on a monotonic clock; replaceable in tests.
    init(
        expectedBytes: Int64,
        now: @escaping @Sendable () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 },
        report: @escaping @Sendable (ScanProgress) -> Void
    ) {
        self.expectedBytes = max(expectedBytes, 1)
        self.now = now
        self.started = now()
        self.report = report
    }

    /// Starts a phase; `total` for a counted one.
    func begin(_ phase: ScanPhase, detail: String? = nil, total: Int? = nil) {
        update { state in
            state.phase = phase
            state.phaseFraction = 0
            state.detail = detail
            state.total = total
            state.completed = total == nil ? nil : 0
        }
    }

    /// Reading progress from the walker.
    func reading(_ progress: ScanProgress) {
        update { state in
            state.items = progress.items
            state.bytes = progress.bytes
            state.path = progress.currentPath
            state.phaseFraction = Double(progress.bytes) / Double(expectedBytes)
        }
    }

    /// Steps of a counted phase done, e.g. worktrees checked. Steps can
    /// finish out of order on several threads; the count only goes up.
    func step(_ done: Int, path: String? = nil) {
        update { state in
            let completed = max(state.completed ?? 0, done)
            state.completed = completed
            if let total = state.total, total > 0 {
                state.phaseFraction = Double(completed) / Double(total)
            }
            if let path { state.path = path }
        }
    }

    private func update(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            let share = Self.shares[state.phase] ?? (0, 0)
            let fraction = min(share.start + share.width * min(state.phaseFraction, 0.99), 0.99)
            state.published = max(state.published, fraction)

            let time = now()
            if let sampleTime = state.sampleTime {
                let elapsed = time - sampleTime
                if elapsed >= Self.sampleInterval {
                    let rate = (state.published - state.sampleFraction) / elapsed
                    state.rate = state.rate.map { Self.smoothing * rate + (1 - Self.smoothing) * $0 } ?? rate
                    state.sampleTime = time
                    state.sampleFraction = state.published
                }
            } else {
                state.sampleTime = time
                state.sampleFraction = state.published
            }
            var remaining: Double?
            if time - started >= Self.warmUp, let rate = state.rate, rate > 0 {
                remaining = (1 - state.published) / rate
            }
            report(ScanProgress(
                items: state.items, bytes: state.bytes, currentPath: state.path, phase: state.phase,
                fraction: state.published, secondsRemaining: remaining, detail: state.detail,
                completed: state.completed, total: state.total))
        }
    }
}
