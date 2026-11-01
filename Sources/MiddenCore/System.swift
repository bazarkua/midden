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
        return DiskSpace(total: Int64(info.f_blocks) * block, free: Int64(info.f_bavail) * block)
    }

    /// Without Full Disk Access, macOS refuses to list these folders even to
    /// their owner.
    static func needsFullDiskAccess(home: String) -> Bool {
        let reader = DirectoryReader(bufferSize: 16 * 1024)
        for relative in ["Library/Safari", "Library/Mail", ".Trash"] {
            do {
                _ = try reader.entries(atPath: home + "/" + relative)
            } catch {
                if error.code == .EPERM || error.code == .EACCES { return true }
            }
        }
        return false
    }
}

extension System {
    /// Runs blocking work on its own thread and waits at most `seconds`.
    /// Returns nil on timeout; the work then finishes, or stays blocked, on
    /// its own thread.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () -> T
    ) -> T? {
        let box = LockedBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
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
