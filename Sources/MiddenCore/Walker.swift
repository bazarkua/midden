import Foundation
import Synchronization

// A parallel, single-pass walk of a directory tree that yields the size of
// every directory it was asked to remember.
//
// Directories are listed on a fixed pool of threads. Listing is blocking
// system calls, so it stays off the Swift cooperative pool, which assumes its
// threads never block.
//
// Sizes are aggregated post-order without a second pass: each directory
// counts its outstanding subdirectories (plus one for its own listing). The
// thread that brings the count to zero adds the directory's total to its
// parent and decrements the parent's count, and so on up the tree.

/// Decisions the walker leaves to its caller: which directories to remember,
/// what each subdirectory inherits, and what to skip. The walker itself knows
/// nothing about rules.
protocol WalkDelegate: Sendable {
    /// What a directory hands down to its subdirectories.
    associatedtype Context: Sendable
    /// What the delegate attaches to a directory it wants sized.
    associatedtype Mark: Sendable

    func rootContext() -> Context

    /// Called once for every directory, on a walker thread, after it was listed.
    func visit(_ directory: VisitedDirectory<Context>) -> Visit<Context, Mark>
}

struct VisitedDirectory<Context: Sendable> {
    var path: String
    var name: String
    /// 0 for the root.
    var depth: Int
    /// What the parent's visit handed down.
    var context: Context
    var entries: [DirectoryEntry]
}

struct Visit<Context: Sendable, Mark: Sendable> {
    /// Non-nil to have the directory's total and its children's sizes recorded.
    var mark: Mark?
    /// Handed to every subdirectory.
    var childContext: Context
    /// Names of subdirectories not to enter. Their size is not counted.
    var excluded: [String] = []
}

/// A directory the delegate marked: its total and its children's sizes.
final class SizedDirectory<Mark: Sendable>: Sendable {
    struct Child: Sendable {
        var name: String
        var bytes: Int64
        var isDirectory: Bool
    }

    let path: String
    let mark: Mark?
    private let state = Mutex<(total: Int64, children: [Child])>((0, []))

    init(path: String, mark: Mark?) {
        self.path = path
        self.mark = mark
    }

    /// Files smaller than this aren't remembered individually; they end up in
    /// the "Other" part of a breakdown.
    static var smallestRecordedFile: Int64 { 1_000_000 }

    var total: Int64 { state.withLock { $0.total } }
    var children: [Child] { state.withLock { $0.children } }

    fileprivate func add(_ child: Child) {
        state.withLock { $0.children.append(child) }
    }

    fileprivate func finish(total: Int64) {
        state.withLock { $0.total = total }
    }
}

struct WalkResult<Mark: Sendable> {
    var totalBytes: Int64
    /// Entries listed: files, folders, symlinks.
    var items: Int64
    /// Directories that couldn't be listed (permissions, I/O errors).
    var unreadable: Int
    /// Marked directories, in no particular order.
    var marked: [SizedDirectory<Mark>]
    /// The root, with the sizes of its immediate children.
    var root: SizedDirectory<Mark>?
}

/// Thread-safe flag a caller sets to stop a walk early.
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

final class Walker<Delegate: WalkDelegate>: Sendable {
    typealias Mark = Delegate.Mark

    let root: String
    let delegate: Delegate
    let threadCount: Int

    private let queue = WorkQueue<Node>()
    private let hardLinks = HardLinkSet()
    private let marked = Mutex<[SizedDirectory<Mark>]>([])
    private let rootRecord = Mutex<SizedDirectory<Mark>?>(nil)
    private let rootTotal = Atomic<Int64>(0)
    private let items = Atomic<Int64>(0)
    private let bytesSeen = Atomic<Int64>(0)
    private let unreadable = Atomic<Int>(0)
    private let lastProgress = Atomic<UInt64>(0)

    static var defaultThreadCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12)
    }

    init(root: String, delegate: Delegate, threadCount: Int = Walker.defaultThreadCount) {
        self.root = root
        self.delegate = delegate
        self.threadCount = max(threadCount, 1)
    }

    /// Walks the tree and blocks until done. Never follows symlinks and never
    /// leaves the root's volume.
    func run(
        cancellation: CancellationFlag = CancellationFlag(),
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) throws(POSIXError) -> WalkResult<Mark> {
        var info = stat()
        guard lstat(root, &info) == 0 else { throw POSIXError(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        let device = info.st_dev

        queue.push([Node(
            path: root, name: (root as NSString).lastPathComponent, depth: 0, parent: nil,
            parentRecord: nil, context: delegate.rootContext(),
            initialBytes: Int64(info.st_blocks) * 512)])

        let done = DispatchGroup()
        for index in 0..<threadCount {
            done.enter()
            let thread = Thread { [self] in
                // Never download iCloud or File Provider content: listing a
                // folder whose contents aren't on disk fails instead.
                setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                    IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                work(device: device, cancellation: cancellation, progress: progress)
                done.leave()
            }
            thread.name = "midden.walker.\(index)"
            thread.stackSize = 1 << 20
            thread.start()
        }
        done.wait()

        return WalkResult(
            totalBytes: rootTotal.load(ordering: .acquiring),
            items: items.load(ordering: .relaxed),
            unreadable: unreadable.load(ordering: .relaxed),
            marked: marked.withLock { $0 },
            root: rootRecord.withLock { $0 })
    }

    private func work(
        device: dev_t,
        cancellation: CancellationFlag,
        progress: @Sendable (ScanProgress) -> Void
    ) {
        let reader = DirectoryReader()
        while let first = queue.pop() {
            // Depth-first: keep one subdirectory for this thread, share the rest.
            var next: Node? = first
            while let node = next {
                if cancellation.isCancelled {
                    next = nil
                } else {
                    next = process(node, reader: reader, device: device)
                    reportProgress(path: node.path, progress)
                }
            }
            queue.finishedChain()
        }
    }

    /// Lists one directory and queues its subdirectories. Returns one of them
    /// for the calling thread to continue with.
    private func process(_ node: Node, reader: DirectoryReader, device: dev_t) -> Node? {
        let entries: [DirectoryEntry]
        do {
            entries = try reader.entries(atPath: node.path)
        } catch {
            // Gone since its parent was listed, or not downloaded: not an error.
            if ![ENOENT, ENOTDIR, EDEADLK].contains(error.code.rawValue) {
                unreadable.add(1, ordering: .relaxed)
            }
            if node.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
                complete(node, record: nil)
            }
            return nil
        }

        let visit = delegate.visit(VisitedDirectory(
            path: node.path, name: node.name, depth: node.depth,
            context: node.context, entries: entries))
        var record: SizedDirectory<Mark>?
        if visit.mark != nil || node.depth == 0 {
            let sized = SizedDirectory(path: node.path, mark: visit.mark)
            if node.depth == 0 {
                rootRecord.withLock { $0 = sized }
            } else {
                marked.withLock { $0.append(sized) }
            }
            record = sized
        }

        var own: Int64 = 0
        var children: [Node] = []
        for entry in entries {
            if entry.kind == .directory {
                // A different device means a mount point: another volume.
                guard entry.device == device, !visit.excluded.contains(entry.name) else {
                    continue
                }
                children.append(Node(
                    path: node.path + "/" + entry.name, name: entry.name,
                    depth: node.depth + 1, parent: node, parentRecord: record,
                    context: visit.childContext, initialBytes: entry.allocatedSize))
            } else {
                var size = entry.allocatedSize
                // A file with several hard links is counted where it's seen first.
                if entry.linkCount > 1, !hardLinks.insert(entry.inode) {
                    size = 0
                }
                own += size
                if let record, size >= SizedDirectory<Mark>.smallestRecordedFile {
                    record.add(.init(name: entry.name, bytes: size, isDirectory: false))
                }
            }
        }

        items.add(Int64(entries.count), ordering: .relaxed)
        bytesSeen.add(own, ordering: .relaxed)
        node.bytes.add(own, ordering: .relaxed)

        var keep: Node?
        if !children.isEmpty {
            node.remaining.add(children.count, ordering: .relaxed)
            keep = children.removeLast()
            if !children.isEmpty { queue.push(children) }
        }
        if node.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            complete(node, record: record)
        }
        return keep
    }

    /// Called when a directory and everything below it is counted. Propagates
    /// its total to its parent, finishing the parent too if it was the last.
    private func complete(_ node: Node, record: SizedDirectory<Mark>?) {
        var node = node
        var record = record
        while true {
            let total = node.bytes.load(ordering: .acquiring)
            record?.finish(total: total)
            guard let parent = node.parent else {
                rootTotal.store(total, ordering: .releasing)
                return
            }
            node.parentRecord?.add(.init(name: node.name, bytes: total, isDirectory: true))
            parent.bytes.add(total, ordering: .relaxed)
            guard parent.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0
            else { return }
            record = node.parentRecord
            node = parent
        }
    }

    private func reportProgress(path: String, _ progress: @Sendable (ScanProgress) -> Void) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let last = lastProgress.load(ordering: .relaxed)
        guard now &- last >= 200_000_000,
            lastProgress.compareExchange(
                expected: last, desired: now, ordering: .relaxed
            ).exchanged
        else { return }
        progress(ScanProgress(
            items: items.load(ordering: .relaxed),
            bytes: bytesSeen.load(ordering: .relaxed),
            currentPath: path))
    }

    /// A directory being counted. Holds its parent until it's complete.
    final class Node: Sendable {
        let path: String
        let name: String
        let depth: Int
        let parent: Node?
        /// The parent's record, if the parent is marked or is the root.
        let parentRecord: SizedDirectory<Mark>?
        let context: Delegate.Context
        /// Subdirectories not yet complete, plus one until it's listed.
        let remaining = Atomic<Int>(1)
        let bytes: Atomic<Int64>

        init(
            path: String, name: String, depth: Int, parent: Node?,
            parentRecord: SizedDirectory<Mark>?, context: Delegate.Context,
            initialBytes: Int64
        ) {
            self.path = path
            self.name = name
            self.depth = depth
            self.parent = parent
            self.parentRecord = parentRecord
            self.context = context
            self.bytes = Atomic(initialBytes)
        }
    }
}

/// A LIFO work list shared by the walker threads. `pop` blocks while other
/// threads may still produce work and returns nil once all of it is done.
final class WorkQueue<Element: Sendable>: @unchecked Sendable {
    // All mutable state below is guarded by `condition`.
    private let condition = NSCondition()
    private var stack: [Element] = []
    /// Threads holding work popped from this queue.
    private var busy = 0
    private var finished = false

    func push(_ elements: [Element]) {
        condition.lock()
        stack.append(contentsOf: elements)
        condition.unlock()
        if elements.count == 1 { condition.signal() } else { condition.broadcast() }
    }

    func pop() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && !finished {
            if busy == 0 {
                finished = true
                condition.broadcast()
                break
            }
            condition.wait()
        }
        if finished { return nil }
        busy += 1
        return stack.removeLast()
    }

    /// A thread finished the work it popped, including what it kept for itself.
    func finishedChain() {
        condition.lock()
        busy -= 1
        let idle = busy == 0 && stack.isEmpty
        if idle { finished = true }
        condition.unlock()
        if idle { condition.broadcast() }
    }
}

/// Inode numbers of files with several hard links, so each is counted once.
/// Sharded to keep walker threads from contending on one lock.
final class HardLinkSet: Sendable {
    private final class Shard: Sendable {
        let inodes = Mutex<Set<UInt64>>([])
    }

    private let shards = (0..<64).map { _ in Shard() }

    /// Returns true the first time an inode is seen.
    func insert(_ inode: UInt64) -> Bool {
        shards[Int(inode % 64)].inodes.withLock { $0.insert(inode).inserted }
    }
}

/// A delegate that only sums sizes.
struct SizeOnly: WalkDelegate {
    func rootContext() {}
    func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, Never> {
        Visit(mark: nil, childContext: ())
    }
}
