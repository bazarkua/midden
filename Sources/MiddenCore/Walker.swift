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
//
// A listing can block indefinitely: open() waits while macOS shows a privacy
// prompt ("would like to access data from other apps") that nobody answers,
// and a hung network or File Provider mount can do the same. A scan must
// always finish, so the walker has a watchdog:
//
// - Each worker publishes the folder it is listing and a heartbeat, which
//   the reader bumps after every getattrlistbulk batch. A huge folder that
//   is still being read keeps beating; a blocked open() doesn't.
// - The thread that called run() supervises. When a listing hasn't beaten
//   for `stallTimeout`, it claims the folder with a compare-and-swap on the
//   folder's state (listing -> given up), counts it as unreadable, finishes
//   its parent's countdown as if the listing had failed, ends the stuck
//   worker's work item on the queue, and starts a replacement worker.
// - The stuck thread can't be cancelled, but whenever its call returns it
//   tries the same compare-and-swap (listing -> listed), loses, drops the
//   result and exits. Nothing it read reaches the totals or the delegate.
//
// The walk ends when the queue is drained; it never waits for a stuck thread.

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
    /// Names of subdirectories not to enter that count as unreadable, e.g.
    /// privacy-protected folders without Full Disk Access.
    var unreadable: [String] = []
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
    /// Why the root itself couldn't be listed; nil when it could.
    var rootError: POSIXError?
    /// Folders whose listing stopped making progress and was given up.
    var stalled: [String] = []
    /// Files and folders at or above `mapFloor`, for the space map.
    var spaceRecords: [SpaceRecord] = []
    /// Marked directories, in no particular order.
    var marked: [SizedDirectory<Mark>]
    /// The root, with the sizes of its immediate children.
    var root: SizedDirectory<Mark>?
}

/// How far a walk is, reported a few times per second.
struct WalkProgress: Sendable {
    var items: Int64
    var bytes: Int64
    var path: String
}

/// Thread-safe flag a caller sets to stop a walk early.
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

final class Walker<Delegate: WalkDelegate>: Sendable {
    typealias Mark = Delegate.Mark

    /// Lists a folder. Replaceable in tests to simulate a folder that blocks.
    typealias Lister = @Sendable (_ path: String, _ reader: DirectoryReader) throws(POSIXError) -> [DirectoryEntry]

    let root: String
    let delegate: Delegate
    let threadCount: Int
    /// A listing without progress for this long is given up.
    let stallTimeout: TimeInterval
    /// Remember files and folders at least this big, for the space map.
    let mapFloor: Int64?
    private let lister: Lister
    private let spaceRecords = Mutex<[SpaceRecord]>([])

    private let queue = WorkQueue<Node>()
    private let workers = Mutex<[Worker]>([])
    private let stalled = Mutex<[String]>([])
    private let hardLinks = HardLinkSet()
    private let marked = Mutex<[SizedDirectory<Mark>]>([])
    private let rootRecord = Mutex<SizedDirectory<Mark>?>(nil)
    private let rootTotal = Atomic<Int64>(0)
    private let items = Atomic<Int64>(0)
    private let bytesSeen = Atomic<Int64>(0)
    private let unreadable = Atomic<Int>(0)
    private let rootError = Atomic<Int32>(0)
    private let lastProgress = Atomic<UInt64>(0)

    init(
        root: String, delegate: Delegate, threadCount: Int = WalkDefaults.threadCount,
        stallTimeout: TimeInterval = WalkDefaults.stallTimeout,
        mapFloor: Int64? = nil,
        lister: @escaping Lister = { path, reader throws(POSIXError) in try reader.entries(atPath: path) }
    ) {
        self.root = root
        self.delegate = delegate
        self.threadCount = max(threadCount, 1)
        self.stallTimeout = stallTimeout
        self.mapFloor = mapFloor
        self.lister = lister
    }

    /// Walks the tree and blocks until done. Never follows symlinks and never
    /// leaves the root's volume.
    func run(
        cancellation: CancellationFlag = CancellationFlag(),
        progress: @escaping @Sendable (WalkProgress) -> Void = { _ in }
    ) throws(POSIXError) -> WalkResult<Mark> {
        var info = stat()
        guard lstat(root, &info) == 0 else { throw POSIXError(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        let device = info.st_dev

        queue.push([Node(
            path: root, name: (root as NSString).lastPathComponent, depth: 0, parent: nil,
            parentRecord: nil, context: delegate.rootContext(),
            initialBytes: Int64(info.st_blocks) * 512)])

        for _ in 0..<threadCount {
            startWorker(device: device, cancellation: cancellation, progress: progress)
        }
        supervise(device: device, cancellation: cancellation, progress: progress)

        return WalkResult(
            totalBytes: rootTotal.load(ordering: .acquiring),
            items: items.load(ordering: .relaxed),
            unreadable: unreadable.load(ordering: .relaxed),
            rootError: rootError.load(ordering: .relaxed) == 0
                ? nil : POSIXError(rootError.load(ordering: .relaxed)),
            stalled: stalled.withLock { $0 },
            spaceRecords: spaceRecords.withLock { $0 },
            marked: marked.withLock { $0 },
            root: rootRecord.withLock { $0 })
    }

    private func startWorker(
        device: dev_t, cancellation: CancellationFlag,
        progress: @escaping @Sendable (WalkProgress) -> Void
    ) {
        let worker = Worker()
        let index = workers.withLock { workers in
            workers.append(worker)
            return workers.count
        }
        let thread = Thread { [self] in
            // Never download iCloud or File Provider content: listing a
            // folder whose contents aren't on disk fails instead.
            setiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            work(worker, device: device, cancellation: cancellation, progress: progress)
        }
        thread.name = "midden.walker.\(index)"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Runs on the thread that called run() until the queue is drained,
    /// giving up listings that stopped making progress.
    private func supervise(
        device: dev_t, cancellation: CancellationFlag,
        progress: @escaping @Sendable (WalkProgress) -> Void
    ) {
        let timeout = UInt64(stallTimeout * 1e9)
        let tick = min(max(stallTimeout / 4, 0.01), 0.25)
        while !queue.waitUntilFinished(timeout: tick) {
            for worker in workers.withLock({ $0 }) where !worker.isAbandoned {
                // Read the clock after the worker's timestamp, which may be newer
                // than any clock reading taken before it.
                guard let (node, since) = worker.listing,
                    clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= since + timeout,
                    node.state.compareExchange(
                        expected: Node.listing, desired: Node.givenUp, ordering: .acquiringAndReleasing
                    ).exchanged
                else { continue }
                worker.abandon()
                stalled.withLock { $0.append(node.path) }
                failed(node, code: ETIMEDOUT)
                queue.finishedChain()  // On behalf of the stuck worker.
                startWorker(device: device, cancellation: cancellation, progress: progress)
            }
        }
    }

    private func work(
        _ worker: Worker,
        device: dev_t,
        cancellation: CancellationFlag,
        progress: @Sendable (WalkProgress) -> Void
    ) {
        let reader = DirectoryReader()
        reader.onBatch = { worker.beat() }
        while let first = queue.pop() {
            // Depth-first: keep one subdirectory for this thread, share the rest.
            var next: Node? = first
            while let node = next {
                if cancellation.isCancelled {
                    next = nil
                    continue
                }
                guard let kept = process(node, reader: reader, worker: worker, device: device) else {
                    // The watchdog gave up this listing and has taken over.
                    return
                }
                next = kept.next
                reportProgress(path: node.path, progress)
            }
            queue.finishedChain()
        }
    }

    /// Counts a folder that couldn't be listed and finishes it.
    private func failed(_ node: Node, code: Int32) {
        // Gone since its parent was listed, or not downloaded: not an error.
        if ![ENOENT, ENOTDIR, EDEADLK].contains(code) {
            unreadable.add(1, ordering: .relaxed)
        }
        if node.depth == 0 { rootError.store(code, ordering: .relaxed) }
        if node.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            complete(node, record: nil)
        }
    }

    private struct Kept {
        var next: Node?
    }

    /// Lists one directory and queues its subdirectories. Returns one of them
    /// for the calling thread to continue with, or nil if the watchdog gave
    /// up this listing meanwhile.
    private func process(_ node: Node, reader: DirectoryReader, worker: Worker, device: dev_t) -> Kept? {
        worker.begin(node)
        let listing = Result { () throws(POSIXError) in try lister(node.path, reader) }
        worker.end()
        guard node.state.compareExchange(
            expected: Node.listing, desired: Node.listed, ordering: .acquiringAndReleasing
        ).exchanged else {
            return nil
        }
        let entries: [DirectoryEntry]
        switch listing {
        case .success(let listed):
            entries = listed
        case .failure(let error):
            failed(node, code: error.code.rawValue)
            return Kept(next: nil)
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
                if visit.unreadable.contains(entry.name) {
                    unreadable.add(1, ordering: .relaxed)
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
                if let mapFloor, size >= mapFloor {
                    let item = SpaceRecord(
                        path: node.path + "/" + entry.name, bytes: size, isDirectory: false, entries: 0)
                    spaceRecords.withLock { $0.append(item) }
                }
                if let record, size >= SizedDirectory<Mark>.smallestRecordedFile {
                    record.add(.init(name: entry.name, bytes: size, isDirectory: false))
                }
            }
        }

        node.entries.store(entries.count, ordering: .relaxed)
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
        return Kept(next: keep)
    }

    /// Called when a directory and everything below it is counted. Propagates
    /// its total to its parent, finishing the parent too if it was the last.
    private func complete(_ node: Node, record: SizedDirectory<Mark>?) {
        var node = node
        var record = record
        while true {
            let total = node.bytes.load(ordering: .acquiring)
            record?.finish(total: total)
            if let mapFloor, total >= mapFloor || node.parent == nil {
                let item = SpaceRecord(
                    path: node.path, bytes: total, isDirectory: true,
                    entries: node.entries.load(ordering: .relaxed))
                spaceRecords.withLock { $0.append(item) }
            }
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

    private func reportProgress(path: String, _ progress: @Sendable (WalkProgress) -> Void) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let last = lastProgress.load(ordering: .relaxed)
        guard now &- last >= 200_000_000,
            lastProgress.compareExchange(
                expected: last, desired: now, ordering: .relaxed
            ).exchanged
        else { return }
        progress(WalkProgress(
            items: items.load(ordering: .relaxed),
            bytes: bytesSeen.load(ordering: .relaxed),
            path: path))
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
        /// Entries in its listing, for the space map.
        let entries = Atomic<Int>(0)
        /// Who finishes the listing: its worker, or the watchdog giving up.
        let state = Atomic<UInt8>(Node.listing)
        static var listing: UInt8 { 0 }
        static var listed: UInt8 { 1 }
        static var givenUp: UInt8 { 2 }
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

extension Walker {
    /// What one walker thread is doing, for the watchdog.
    final class Worker: Sendable {
        /// The folder being listed and the last sign of progress (uptime ns).
        private let current = Mutex<(node: Node, since: UInt64)?>(nil)
        private let abandoned = Atomic<Bool>(false)

        var listing: (Node, UInt64)? { current.withLock { $0.map { ($0.node, $0.since) } } }
        var isAbandoned: Bool { abandoned.load(ordering: .relaxed) }

        func begin(_ node: Node) {
            current.withLock { $0 = (node, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
        }

        func beat() {
            current.withLock { $0?.since = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        }

        func end() {
            current.withLock { $0 = nil }
        }

        func abandon() {
            abandoned.store(true, ordering: .relaxed)
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

    /// Waits until all work is done, at most `timeout` seconds. Returns
    /// whether it's done.
    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !finished { condition.wait(until: Date(timeIntervalSinceNow: timeout)) }
        return finished
    }

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
