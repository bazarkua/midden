import Foundation

// Public entry points of MiddenCore: the API front ends (the CLI, an app) build against.

public struct ScanOptions: Sendable {
    /// Folder to scan. Defaults to the current user's home.
    public var home: URL
    /// Findings smaller than this are left out of the report.
    public var minimumBytes: Int64
    /// The previous scan's `bytesScanned`, if the app has one. Makes the
    /// progress estimate much closer; without it the volume's used space
    /// is the (pessimistic) estimate.
    public var expectedBytes: Int64?
    /// The previous scan's `itemsScanned`, if the app has one. The walk's
    /// time follows items more closely than bytes.
    public var expectedItems: Int64?
    /// Walker threads; nil picks a default for this Mac.
    var threadCount: Int?
    /// Build folders whose project changed more recently are "review".
    var projectIdleWindow: TimeInterval = Findings.projectIdleWindow
    /// Worktrees used more recently are "review".
    var worktreeActiveWindow: TimeInterval = 7 * 86_400
    /// Whether Full Disk Access is granted; nil asks the system.
    var fullDiskAccess: Bool?
    /// The account home whose folders macOS protects; nil is the real one.
    /// Separate from `home`, which can be any folder.
    var privacyHome: String?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        minimumBytes: Int64 = 50_000_000
    ) {
        self.home = home
        self.minimumBytes = minimumBytes
    }
}

/// Whether this process has Full Disk Access.
public enum FullDiskAccess {
    /// Tries to list folders macOS opens only to apps with Full Disk Access
    /// (~/Library/Safari, ~/Library/Mail, ~/.Trash). Granted only when one
    /// of them lists and none is refused. Folders that don't exist prove
    /// nothing, and an unproven answer is "no": a scan that wrongly assumed
    /// access would open Desktop, Documents and Downloads and raise a
    /// permission prompt for each. Gives up after a few seconds and returns
    /// false, so it never hangs the caller. Blocks: call it off the main
    /// thread.
    public static func isGranted(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = (try? System.canonicalPath(home.path)) ?? home.path
        return System.withDeadline(WalkDefaults.stallTimeout, threads: probeThreads) {
            System.fullDiskAccessProbe(home: path) == true
        } ?? false
    }

    /// Probes still blocked from earlier calls. Past two, the answer is "no
    /// access" without starting another.
    static let probeThreads = DeadlineThreads(limit: 2)

    /// `isGranted(home:)` without blocking the caller: the probe runs on its
    /// own thread. (Not an `async` overload of `isGranted`, which would make
    /// existing calls in async code pick it and need `await`.)
    public static func check(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> Bool {
        (try? await Background.run { isGranted(home: home) }) ?? false
    }
}

public enum MiddenError: Error, Sendable, Equatable {
    case notImplemented
    /// The scanning task was cancelled.
    case cancelled
    /// The folder to scan couldn't be read at all, usually for lack of
    /// permission. `code` is the errno. Show "no access", never "nothing to
    /// clean".
    case unreadable(path: String, code: Int32)
}

extension MiddenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented."
        case .cancelled: "The scan was cancelled."
        case .unreadable(let path, let code):
            "Midden can't read \(path): \(String(cString: strerror(code)))."
        }
    }
}

public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans `options.home`. `progress` is called from a background thread a
    /// few times per second.
    ///
    /// Cancelling the task that awaits this stops the walk within a folder
    /// listing or so and throws `MiddenError.cancelled`. Throws
    /// `MiddenError.unreadable` when the folder can't be read at all.
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
    /// Replaces moving to the Trash, so tests never touch the user's Trash.
    var trash: (@Sendable (String) throws -> Void)?
    /// Lets tests change the file system at a chosen stage of cleaning.
    var barrier: (@Sendable (CleanStage, String) -> Void)?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private func makeEngine() throws -> CleanEngine {
        var engine = try CleanEngine(home: home)
        if let trash { engine.trash = trash }
        if let barrier { engine.barrier = barrier }
        return engine
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
            guard let engine = try? makeEngine() else {
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
        let plans = try? await Background.run { () -> [CleanPlan] in
            guard let engine = try? makeEngine() else {
                return ids.map { CleanPlan(id: $0, finding: nil, refusal: "Can't read the home folder.") }
            }
            return ids.map(engine.plan)
        }
        return plans ?? []
    }
}
