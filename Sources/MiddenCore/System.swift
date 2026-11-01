import Foundation
import Synchronization

enum System {
    /// The path with symlinks resolved (on macOS /var is /private/var).
    static func canonicalPath(_ path: String) throws(POSIXError) -> String {
        guard let resolved = realpath(path, nil) else { throw POSIXError(errno) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Size and free space of the volume holding `path`, as statfs(2)
    /// reports them: free is what an unprivileged user can write.
    static func diskSpace(_ path: String) -> DiskSpace {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return DiskSpace(total: 0, free: 0) }
        let block = Int64(info.f_bsize)
        let name = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey])
            .volumeLocalizedName
        return DiskSpace(
            total: Int64(info.f_blocks) * block, free: Int64(info.f_bavail) * block, volumeName: name)
    }

    /// Where every file system is mounted, from the kernel's mount table.
    /// Nil when the table can't be read.
    static func mountPoints() -> [String]? {
        var table: UnsafeMutablePointer<statfs>?
        // The _r_np variant gives this call its own buffer; getmntinfo
        // reuses one shared buffer and isn't thread-safe.
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else { return nil }
        defer { free(table) }
        return (0..<Int(count)).map { index in
            withUnsafeBytes(of: table[index].f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    /// Files and folders on the volume holding `path`, an upper bound on
    /// the items under it. Nil when the file system doesn't say.
    static func usedInodes(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_files > info.f_ffree else { return nil }
        return Int64(info.f_files - info.f_ffree)
    }

    /// Without Full Disk Access, macOS refuses to list these folders even to
    /// their owner, at once and without a prompt (measured on macOS 27).
    static let fullDiskAccessProbes = ["Library/Safari", "Library/Mail", ".Trash"]

    /// True when a protected folder could be listed, false when one was
    /// refused, nil when none of them settles it (absent, or another error).
    static func fullDiskAccessProbe(home: String) -> Bool? {
        let reader = DirectoryReader(bufferSize: 16 * 1024)
        var granted: Bool?
        for relative in fullDiskAccessProbes {
            do {
                _ = try reader.entries(atPath: home + "/" + relative)
                granted = true
            } catch {
                if error.code == .EPERM || error.code == .EACCES { return false }
            }
        }
        return granted
    }
}

/// Threads started by `withDeadline` calls that share this value and haven't
/// finished: a timed-out call leaves its thread running, maybe forever.
final class DeadlineThreads: Sendable {
    let limit: Int
    private let running = Atomic<Int>(0)

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { running.load(ordering: .relaxed) }

    func admit() -> Bool {
        var current = running.load(ordering: .relaxed)
        while current < limit {
            let (exchanged, original) = running.compareExchange(
                expected: current, desired: current + 1, ordering: .relaxed)
            if exchanged { return true }
            current = original
        }
        return false
    }

    func release() {
        running.subtract(1, ordering: .relaxed)
    }
}

extension System {
    /// Runs blocking work on its own thread and waits at most `seconds`.
    /// Returns nil on timeout; the work then finishes, or stays blocked, on
    /// its own thread. With `threads`, at most its limit of those threads
    /// run at once: past it the call returns nil without starting another.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, threads: DeadlineThreads? = nil, _ work: @escaping @Sendable () -> T
    ) -> T? {
        if let threads, !threads.admit() { return nil }
        let box = LockedBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            defer { threads?.release() }
            let result = work()
            box.value.withLock { $0 = result }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value.withLock { $0 }
    }
}

/// A value shared between threads.
final class LockedBox<T: Sendable>: Sendable {
    let value = Mutex<T?>(nil)
}

enum Background {
    /// Runs blocking work on a new thread, keeping it off the Swift
    /// cooperative pool, whose threads must never block.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "midden.background"
            thread.start()
        }
    }

    /// Maps on several threads, keeping the order.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T], _ transform: @Sendable (T) -> R
    ) -> [R] {
        let results = ResultBox<R>()
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let value = transform(items[index])
            results.values.withLock { $0[index] = value }
        }
        return results.values.withLock { values in items.indices.map { values[$0]! } }
    }

    private final class ResultBox<R: Sendable>: Sendable {
        let values = Mutex<[Int: R]>([:])
    }
}
