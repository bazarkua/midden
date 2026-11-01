import Foundation

/// Runs one stage of a scan on its own, so the benchmark tool in
/// Benchmarks/midden-bench can time where a scan spends its time.
///
/// `package` access: visible to the targets of this package only, so the
/// public API doesn't change. Unlike `@testable import`, it works in release
/// builds, which are the ones worth timing.
package enum Benchmark {
    package enum Stage: String, CaseIterable, Sendable {
        /// The walker alone: list every folder, add up allocated sizes,
        /// count hard links once. What a C scanner does.
        case walk
        /// The walk plus classifying every folder (`ScanDelegate`).
        case classify
        /// The scan's reading phase as `ScanEngine` runs it: classifying
        /// plus the records for the space map.
        case read
        /// The whole scan through the public `Scanner`: reading, worktree
        /// audits, simulators and the report, without JSON encoding.
        case scan
    }

    package struct Outcome: Sendable {
        package var items: Int64
        package var bytes: Int64
        package var readErrors: Int
        package var seconds: Double
    }

    /// The thread count a scan uses when none is given.
    package static var defaultThreads: Int { WalkDefaults.threadCount }

    package static func run(_ stage: Stage, root: String, threads: Int? = nil) async throws -> Outcome {
        let threadCount = threads ?? WalkDefaults.threadCount
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        func outcome(items: Int64, bytes: Int64, readErrors: Int) -> Outcome {
            let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9
            return Outcome(items: items, bytes: bytes, readErrors: readErrors, seconds: seconds)
        }

        switch stage {
        case .walk:
            let path = try System.canonicalPath(root)
            let walk = try Walker(root: path, delegate: SizeOnly(), threadCount: threadCount).run()
            return outcome(items: walk.items, bytes: walk.totalBytes, readErrors: walk.readErrors)
        case .classify, .read:
            let path = try System.canonicalPath(root)
            // As ScanEngine decides it.
            let fullDiskAccess = FullDiskAccess.isGranted(home: URL(fileURLWithPath: path))
            let walk = try Walker(
                root: path, delegate: ScanDelegate(skipProtected: !fullDiskAccess),
                threadCount: threadCount,
                mapFloor: stage == .read ? WalkDefaults.mapFloor : nil
            ).run()
            return outcome(items: walk.items, bytes: walk.totalBytes, readErrors: walk.readErrors)
        case .scan:
            var options = ScanOptions(home: URL(fileURLWithPath: root))
            options.threadCount = threadCount
            let report = try await Scanner(options: options).scan()
            return outcome(
                items: report.itemsScanned, bytes: report.bytesScanned, readErrors: report.readErrors)
        }
    }
}
