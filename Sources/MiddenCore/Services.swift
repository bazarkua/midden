import Foundation

// Public entry points of MiddenCore: the API front ends (the CLI, an app) build against.

public struct ScanOptions: Sendable {
    /// Folder to scan. Defaults to the current user's home.
    public var home: URL
    /// Findings smaller than this are left out of the report.
    public var minimumBytes: Int64
    /// Walker threads; nil picks a default for this Mac.
    var threadCount: Int?
    /// Build folders whose project changed more recently are "review".
    var projectIdleWindow: TimeInterval = Findings.projectIdleWindow
    /// Worktrees used more recently are "review".
    var worktreeActiveWindow: TimeInterval = 7 * 86_400

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        minimumBytes: Int64 = 50_000_000
    ) {
        self.home = home
        self.minimumBytes = minimumBytes
    }
}

public enum MiddenError: Error, Sendable {
    case notImplemented
    case cancelled
}

public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans `options.home`. `progress` is called from a background thread a
    /// few times per second.
    public func scan(
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanReport {
        let engine = ScanEngine(options: options)
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Background.run {
                try engine.run(progress: progress, cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

public struct Cleaner: Sendable {
    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Cleans the findings with the given ids. Every id is checked again from
    /// scratch before anything is deleted; ids that no longer qualify are
    /// refused, not trusted from the earlier scan.
    public func clean(
        _ ids: [String],
        progress: @escaping @Sendable (CleanResult) -> Void = { _ in }
    ) async -> CleanSummary {
        let home = self.home
        let summary = try? await Background.run { () -> CleanSummary in
            let freeBefore = System.diskSpace(home.path).free
            guard let engine = try? CleanEngine(home: home) else {
                let results = ids.map { CleanResult(id: $0, ok: false, message: "Can't read the home folder.") }
                results.forEach(progress)
                return CleanSummary(results: results, freeBefore: freeBefore, freeAfter: freeBefore)
            }
            var results: [CleanResult] = []
            for id in ids {
                let result = engine.clean(id)
                progress(result)
                results.append(result)
            }
            return CleanSummary(
                results: results, freeBefore: freeBefore, freeAfter: System.diskSpace(home.path).free)
        }
        return summary ?? CleanSummary(results: [], freeBefore: 0, freeAfter: 0)
    }

    /// What cleaning each id would do, checked the same way `clean` checks
    /// it, without deleting anything. Shown to the user before they confirm.
    public func plan(_ ids: [String]) async -> [CleanPlan] {
        let home = self.home
        let plans = try? await Background.run { () -> [CleanPlan] in
            guard let engine = try? CleanEngine(home: home) else {
                return ids.map { CleanPlan(id: $0, finding: nil, refusal: "Can't read the home folder.") }
            }
            return ids.map(engine.plan)
        }
        return plans ?? []
    }
}
