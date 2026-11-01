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
/// - Reading progress is the larger of two ratios: bytes counted over bytes
///   expected, and items listed over items expected. The app passes the
///   previous scan's totals when it has them, which makes both nearly
///   exact. Otherwise the denominators are the volume's used space and
///   used inodes, which can only overestimate the home folder: the bar
///   under-promises and jumps ahead when reading ends, instead of sitting
///   at 99% while work remains. On a 435 GB home the home was 65% of the
///   used bytes and 63% of the used inodes, so a first scan jumps from
///   about 0.55 to 0.85; nothing cheap measures the home's share better.
///   Items matter because the walk's time follows them: bytes jump when a
///   single huge file is counted (6% to 35% of the denominator in one
///   second on a real home), items grow steadily.
///   Another idea measured and dropped: folders finished over folders
///   found stays between 0.96 and 0.999 for the whole walk, because a
///   depth-first walk finishes folders almost as fast as it finds them.
///   Within a phase the fraction is capped at 99% of its share until the
///   phase really ends, because a stale expected size may be too small.
/// - The worktree phase advances one step per worktree: sized if it's
///   outside home, then audited.
/// - The published fraction never goes backwards (it's the running maximum)
///   and stays below 1: the report itself is the 100%.
/// - Time left comes from how fast the work moves, measured on a pace that
///   follows time rather than bytes: items for reading (so counting one
///   huge file doesn't make the rest look quick), steps in counted phases,
///   placed on the bar with the same shares. On a real home, pacing by the
///   bar itself said 3.5 s left at 5 s into a 27 s scan, right after a
///   large file was counted. The pace's rate is an exponential moving
///   average, sampled at most every 200 ms with weight 0.2 for the newest
///   sample. Each sample gives a raw estimate; the
///   published one is the median of the last 9 raw estimates (about two
///   seconds), so one burst or stall doesn't swing it. It may grow by at
///   most 10% of its value, or 1 s, per second, while it may fall freely:
///   a sudden jump from 20 s to 200 s is far more often noise than news.
///   The 1 s floor lets a small estimate hold still rather than count down
///   to zero while real work remains. It's withheld for the
///   first 2 seconds, while the rate is noise, and while the average rate
///   isn't positive.
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
    static let window = 9
    /// Fastest the published time left may grow, per second: this share of
    /// it, or 1 s, whichever is more.
    static let maximumGrowth = 0.1

    private struct State {
        var phase: ScanPhase = .preparing
        /// Progress within the phase, 0...1.
        var phaseFraction = 0.0
        /// The same, by a measure that follows time (items, not bytes).
        var phasePace = 0.0
        /// Overall pace, 0...1, for the time left. Only goes up.
        var pace = 0.0
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
        var estimates: [Double] = []
        var remaining: Double?
        var remainingTime: TimeInterval = 0
    }

    private let state = Mutex(State())
    private let expectedBytes: Int64
    private let expectedItems: Int64?
    private let started: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let report: @Sendable (ScanProgress) -> Void

    /// - Parameters:
    ///   - expectedBytes: the previous scan's total, or an upper bound.
    ///   - expectedItems: the previous scan's item count, or an upper bound.
    ///   - now: seconds on a monotonic clock; replaceable in tests.
    init(
        expectedBytes: Int64,
        expectedItems: Int64? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 },
        report: @escaping @Sendable (ScanProgress) -> Void
    ) {
        self.expectedBytes = max(expectedBytes, 1)
        self.expectedItems = expectedItems.map { max($0, 1) }
        self.now = now
        self.started = now()
        self.report = report
    }

    /// Starts a phase; `total` for a counted one.
    func begin(_ phase: ScanPhase, detail: String? = nil, total: Int? = nil) {
        update { state in
            state.phase = phase
            state.phaseFraction = 0
            state.phasePace = 0
            state.detail = detail
            state.total = total
            state.completed = total == nil ? nil : 0
        }
    }

    /// Reading progress from the walker.
    func reading(_ progress: WalkProgress) {
        update { state in
            state.items = progress.items
            state.bytes = progress.bytes
            state.path = progress.path
            let byBytes = Double(progress.bytes) / Double(expectedBytes)
            let byItems = expectedItems.map { Double(progress.items) / Double($0) } ?? 0
            state.phaseFraction = max(byBytes, byItems)
            state.phasePace = expectedItems == nil ? byBytes : byItems
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
                state.phasePace = state.phaseFraction
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
            let pace = min(share.start + share.width * min(state.phasePace, 0.99), 0.99)
            state.pace = max(state.pace, pace)

            let time = now()
            if let sampleTime = state.sampleTime {
                let elapsed = time - sampleTime
                if elapsed >= Self.sampleInterval {
                    let rate = (state.pace - state.sampleFraction) / elapsed
                    state.rate = state.rate.map { Self.smoothing * rate + (1 - Self.smoothing) * $0 } ?? rate
                    state.sampleTime = time
                    state.sampleFraction = state.pace
                }
            } else {
                state.sampleTime = time
                state.sampleFraction = state.pace
            }
            if let rate = state.rate, rate > 0, time - started >= Self.warmUp,
                state.sampleTime == time  // A new sample was just taken.
            {
                state.estimates.append((1 - state.pace) / rate)
                if state.estimates.count > Self.window { state.estimates.removeFirst() }
                let median = state.estimates.sorted()[state.estimates.count / 2]
                if let previous = state.remaining {
                    let ceiling = previous
                        + max(previous * Self.maximumGrowth, 1) * (time - state.remainingTime)
                    state.remaining = min(median, ceiling)
                } else {
                    state.remaining = median
                }
                state.remainingTime = time
            }
            let remaining = state.remaining
            report(ScanProgress(
                items: state.items, bytes: state.bytes, currentPath: state.path, phase: state.phase,
                fraction: state.published, secondsRemaining: remaining, detail: state.detail,
                completed: state.completed, total: state.total))
        }
    }
}
