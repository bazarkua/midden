import Foundation

// Public entry points of MiddenCore. These are placeholders that define the
// API front ends build against; the implementations replace them.

public struct ScanOptions: Sendable {
    /// Folder to scan. Defaults to the current user's home.
    public var home: URL
    /// Findings smaller than this are left out of the report.
    public var minimumBytes: Int64

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
        throw MiddenError.notImplemented
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
        CleanSummary(
            results: ids.map { CleanResult(id: $0, ok: false, message: "Not implemented") },
            freeBefore: 0,
            freeAfter: 0
        )
    }
}
