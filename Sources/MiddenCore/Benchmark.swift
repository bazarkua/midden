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
        /// The walk plus classifying every folder (`ScanDelegate`), which
        /// also measures what Logs and SwiftPM cleaning would delete.
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
        /// The report, for the `scan` stage.
        package var report: ScanReport?
    }

    /// The thread count a scan uses when none is given.
    package static var defaultThreads: Int { WalkDefaults.threadCount }

    package static func run(_ stage: Stage, root: String, threads: Int? = nil) async throws -> Outcome {
        let threadCount = threads ?? WalkDefaults.threadCount
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        func outcome(items: Int64, bytes: Int64, readErrors: Int) -> Outcome {
            let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9
            return Outcome(items: items, bytes: bytes, readErrors: readErrors, seconds: seconds, report: nil)
        }

        switch stage {
        case .walk:
            let path = try System.canonicalPath(root)
            let walk = try Walker(root: path, delegate: SizeOnly(), threadCount: threadCount).run()
            // Partial totals would time less work than the other tools did.
            if let rootError = walk.rootError { throw rootError }
            return outcome(items: walk.items, bytes: walk.totalBytes, readErrors: walk.readErrors)
        case .classify, .read:
            let path = try System.canonicalPath(root)
            // As ScanEngine sets it up: Full Disk Access is probed on the
            // account's real home, and protected folders are recognized by
            // where they are in it.
            let accountHome = System.accountHome()
            let fullDiskAccess = FullDiskAccess.isGranted(home: URL(fileURLWithPath: accountHome))
            if !fullDiskAccess, PrivacyProtected.covers(path, accountHome: accountHome) {
                throw POSIXError(.EPERM)
            }
            let delegate = ScanDelegate(skipProtected: !fullDiskAccess, accountHome: accountHome)
            let walk = try Walker(
                root: path, delegate: delegate,
                threadCount: threadCount,
                mapFloor: stage == .read ? WalkDefaults.mapFloor : nil
            ).run()
            // As ScanEngine does right after its walk: take what the walk
            // collected, which includes what Logs and SwiftPM cleaning would
            // delete, measured from the walk's own listings.
            _ = delegate.takeCollected()
            if let rootError = walk.rootError { throw rootError }
            return outcome(items: walk.items, bytes: walk.totalBytes, readErrors: walk.readErrors)
        case .scan:
            var options = ScanOptions(home: URL(fileURLWithPath: root))
            options.threadCount = threadCount
            let report = try await Scanner(options: options).scan()
            var result = outcome(
                items: report.itemsScanned, bytes: report.bytesScanned, readErrors: report.readErrors)
            result.report = report
            return result
        }
    }
}
