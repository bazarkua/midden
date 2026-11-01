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
// - Every stuck thread stays blocked in the kernel, so walker threads are
//   bounded (WalkerThreads): each takes a slot from a budget shared across
//   walks, atomically, before it starts, and gives it back only when it
//   really exits, which for a stuck thread is when its call returns. A
//   walk starts at most `threadCount` replacements, and only while slots
//   are free; with none free it doesn't start at all.
// - Each listing is one ListingOperation. The watchdog registers it as
//   abandoned only if it hasn't returned yet, and the worker unregisters
//   it when it returns, both under the operation's own lock, so a listing
//   that returns while being given up never stays registered. A folder
//   whose listing is still registered from an earlier walk is counted as
//   stalled without being tried again, so scanning the same blocked folder
//   repeatedly doesn't add threads. When no unstuck worker is left, the
//   supervisor counts every folder still queued as unreadable.
// - After run() returns, the walker drops what it collected, so a stuck
//   thread, which still references the walker, keeps only its own chain
//   of folders alive, not the whole scan. (The delegate's collections are
//   its caller's to take; ScanDelegate.takeCollected empties them.)
// - Cancelling gives up every listing in progress at the next tick, so a
//   cancelled walk returns within one tick (at most 0.25 s) even when
//   every thread is blocked.
//
// The walk ends when the queue is drained; it never waits for a stuck thread.

/// Slots for walker threads, shared by every walk given the same value (by
/// default the whole process). A thread holds one from before it starts
/// until it exits, stuck or not, so running plus stuck walker threads never
/// exceed `limit`. Also records the listings given up and not yet returned.
final class WalkerThreads: Sendable {
    let limit: Int
    private struct State {
        var held = 0
        var highWater = 0
        /// Calls of admit() waiting for a slot, for tests.
        var waiting = 0
        /// Folder path -> abandoned listings of it that haven't returned.
        var abandoned: [String: Int] = [:]
    }
    private let state = Mutex(State())

    static let process = WalkerThreads(limit: 64)

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes a slot if one is free, waiting up to `wait` seconds for one.
    /// Never takes one once `cancellation` is set, and stops waiting then:
    /// the check comes before every attempt to reserve.
    func admit(waitingUpTo wait: TimeInterval = 0, cancellation: CancellationFlag? = nil) -> Bool {
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(max(wait, 0) * 1e9)
        var counted = false
        defer { if counted { state.withLock { $0.waiting -= 1 } } }
        while true {
            if cancellation?.isCancelled == true { return false }
            let admitted = state.withLock { state in
                guard state.held < limit else { return false }
                state.held += 1
                state.highWater = max(state.highWater, state.held)
                return true
            }
            if admitted { return true }
            if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline { return false }
            if !counted {
                counted = true
                state.withLock { $0.waiting += 1 }
            }
            usleep(5_000)
        }
    }

    var waiting: Int { state.withLock { $0.waiting } }

    /// A thread that held a slot exited.
    func release() {
        state.withLock { $0.held -= 1 }
    }

    var held: Int { state.withLock { $0.held } }
    /// The most slots held at once, for tests.
    var highWater: Int { state.withLock { $0.highWater } }
    var abandonedCount: Int { state.withLock { $0.abandoned.values.reduce(0, +) } }

    func isAbandoned(_ path: String) -> Bool {
        state.withLock { $0.abandoned[path] != nil }
    }

    fileprivate func register(_ path: String) {
        state.withLock { $0.abandoned[path, default: 0] += 1 }
    }

    fileprivate func unregister(_ path: String) {
        state.withLock { state in
            let left = (state.abandoned[path] ?? 1) - 1
            state.abandoned[path] = left > 0 ? left : nil
        }
    }
}

/// One listing call: the watchdog may give it up while it runs, and the
/// worker acknowledges when it returns. Whichever comes second settles the
/// registration, under this record's lock (then the budget's).
final class ListingOperation: Sendable {
    enum Phase { case running, abandoned, returned }
    let path: String
    private let phase = Mutex<Phase>(.running)

    init(path: String) {
        self.path = path
    }

    var isReturned: Bool { phase.withLock { $0 == .returned } }

    /// The watchdog gave it up: registered unless it already returned.
    func abandon(in threads: WalkerThreads) {
        phase.withLock { phase in
            guard phase == .running else { return }
            phase = .abandoned
            threads.register(path)
        }
    }

    /// The call returned: unregistered if it had been given up.
    func returned(in threads: WalkerThreads) {
        phase.withLock { phase in
            if phase == .abandoned { threads.unregister(path) }
            phase = .returned
        }
    }
}

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
    /// False when some entries couldn't be read: `entries` is then only
    /// part of the folder, and nothing should be concluded from what's
    /// missing (a marker file, a `.git` file).
    var isComplete = true
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
    /// Directories that failed to list (permissions, I/O errors, given up).
    var readErrors: Int
    /// Directories not entered because the delegate said they're unreadable.
    var skipped: Int
    var unreadable: Int { readErrors + skipped }
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
    /// The walk was cancelled: its totals are partial, and that isn't a
    /// read error or a stalled root.
    var cancelled = false
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
    typealias Lister = @Sendable (_ path: String, _ reader: DirectoryReader) throws(POSIXError) -> DirectoryListing

    let root: String
    let delegate: Delegate
    let threadCount: Int
    /// A listing without progress for this long is given up.
    let stallTimeout: TimeInterval
    /// Remember files and folders at least this big, for the space map.
    let mapFloor: Int64?
    /// Slots for walker threads, shared across walks.
    let threads: WalkerThreads
    /// Called between giving up a listing and registering it as abandoned;
    /// tests use it to let the listing return in that gap.
    private let afterGivingUp: (@Sendable (ListingOperation) -> Void)?
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
    private let skipped = Atomic<Int>(0)
    private let rootError = Atomic<Int32>(0)
    private let lastProgress = Atomic<UInt64>(0)

    init(
        root: String, delegate: Delegate, threadCount: Int = WalkDefaults.threadCount,
        stallTimeout: TimeInterval = WalkDefaults.stallTimeout,
        mapFloor: Int64? = nil,
        threads: WalkerThreads = .process,
        lister: @escaping Lister = { path, reader throws(POSIXError) in try reader.listing(atPath: path) },
        afterGivingUp: (@Sendable (ListingOperation) -> Void)? = nil
    ) {
        self.root = root
        self.delegate = delegate
        self.threadCount = max(threadCount, 1)
        self.stallTimeout = stallTimeout
        self.mapFloor = mapFloor
        self.threads = threads
        self.afterGivingUp = afterGivingUp
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

        // As many workers as there are free slots, up to threadCount. The
        // first one waits up to the stall timeout for a slot: other walks'
        // running threads give theirs back when those walks end. If stuck
        // threads hold every slot, none comes, and the walk doesn't start:
        // everything counts as unreadable, the root included. Cancelling
        // stops the wait at once, and a cancelled walk starts nothing; that
        // isn't a stalled root, so nothing is counted as unreadable.
        var started = 0
        while started < threadCount,
            startWorker(
                device: device, cancellation: cancellation, progress: progress,
                waitingUpTo: started == 0 ? stallTimeout : 0)
        {
            started += 1
        }
        if started == 0 {
            if cancellation.isCancelled {
                queue.drain { _ in }
            } else {
                queue.drain { failed($0, code: ETIMEDOUT) }
            }
        }
        supervise(device: device, cancellation: cancellation, progress: progress)
        // A thread still stuck in a listing references this walker; it
        // shouldn't keep what the walk collected alive.
        defer { releaseCollected() }

        return WalkResult(
            totalBytes: rootTotal.load(ordering: .acquiring),
            items: items.load(ordering: .relaxed),
            readErrors: unreadable.load(ordering: .relaxed),
            skipped: skipped.load(ordering: .relaxed),
            rootError: rootError.load(ordering: .relaxed) == 0
                ? nil : POSIXError(rootError.load(ordering: .relaxed)),
            stalled: stalled.withLock { $0 },
            spaceRecords: spaceRecords.withLock { $0 },
            marked: marked.withLock { $0 },
            root: rootRecord.withLock { $0 },
            cancelled: cancellation.isCancelled)
    }

    private func releaseCollected() {
        spaceRecords.withLock { $0 = [] }
        marked.withLock { $0 = [] }
        rootRecord.withLock { $0 = nil }
        workers.withLock { $0 = [] }
        hardLinks.removeAll()
    }

    /// Starts a worker if a slot is free. The thread gives the slot back
    /// when it exits, which for a stuck one is when its call returns.
    @discardableResult
    private func startWorker(
        device: dev_t, cancellation: CancellationFlag,
        progress: @escaping @Sendable (WalkProgress) -> Void,
        waitingUpTo wait: TimeInterval = 0
    ) -> Bool {
        guard threads.admit(waitingUpTo: wait, cancellation: cancellation) else { return false }
        let worker = Worker()
        let index = workers.withLock { workers in
            workers.append(worker)
            return workers.count
        }
        let thread = Thread { [self] in
            defer { threads.release() }
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
        return true
    }

    /// Runs on the thread that called run() until the queue is drained,
    /// giving up listings that stopped making progress.
    private func supervise(
        device: dev_t, cancellation: CancellationFlag,
        progress: @escaping @Sendable (WalkProgress) -> Void
    ) {
        let stallNanoseconds = UInt64(stallTimeout * 1e9)
        let tick = min(max(stallTimeout / 4, 0.01), 0.25)
        var replaced = 0
        while !queue.waitUntilFinished(timeout: tick) {
            // A cancelled walk doesn't wait for slow listings.
            let timeout = cancellation.isCancelled ? 0 : stallNanoseconds
            for worker in workers.withLock({ $0 }) where !worker.isAbandoned {
                // Read the clock after the worker's timestamp, which may be newer
                // than any clock reading taken before it.
                guard let (node, since, operation) = worker.listing,
                    clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= since + timeout,
                    node.state.compareExchange(
                        expected: Node.listing, desired: Node.givenUp, ordering: .acquiringAndReleasing
                    ).exchanged
                else { continue }
                worker.abandon()
                afterGivingUp?(operation)
                operation.abandon(in: threads)
                stalled.withLock { $0.append(node.path) }
                failed(node, code: ETIMEDOUT)
                queue.finishedChain()  // On behalf of the stuck worker.
                if replaced < threadCount,
                    startWorker(device: device, cancellation: cancellation, progress: progress)
                {
                    replaced += 1
                } else if workers.withLock({ $0.allSatisfy(\.isAbandoned) }) {
                    // No thread left to list anything: what's still queued
                    // is counted as unreadable rather than waited for, unless
                    // the walk was cancelled, which reads nothing more anyway.
                    let cancelled = cancellation.isCancelled
                    queue.drain { queued in
                        queued.state.store(Node.givenUp, ordering: .releasing)
                        if !cancelled { failed(queued, code: ETIMEDOUT) }
                    }
                }
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
                    // The thread exits and gives its slot back.
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
        if !Self.isBenign(code) {
            unreadable.add(1, ordering: .relaxed)
        }
        if node.depth == 0 { rootError.store(code, ordering: .relaxed) }
        if node.remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            complete(node, record: nil)
        }
    }

    /// Gone since its parent was listed, or not downloaded: not an error.
    private static func isBenign(_ code: Int32) -> Bool {
        [ENOENT, ENOTDIR, EDEADLK].contains(code)
    }

    private struct Kept {
        var next: Node?
    }

    /// Lists one directory and queues its subdirectories. Returns one of them
    /// for the calling thread to continue with, or nil if the watchdog gave
    /// up this listing meanwhile.
    private func process(_ node: Node, reader: DirectoryReader, worker: Worker, device: dev_t) -> Kept? {
        // A thread from an earlier walk is still blocked listing it: another
        // try would most likely block one more.
        if threads.isAbandoned(node.path) {
            node.state.store(Node.givenUp, ordering: .releasing)
            stalled.withLock { $0.append(node.path) }
            failed(node, code: ETIMEDOUT)
            return Kept(next: nil)
        }
        let operation = worker.begin(node)
        let listing = Result { () throws(POSIXError) in try lister(node.path, reader) }
        operation.returned(in: threads)
        worker.end()
        guard node.state.compareExchange(
            expected: Node.listing, desired: Node.listed, ordering: .acquiringAndReleasing
        ).exchanged else {
            return nil
        }
        let entries: [DirectoryEntry]
        let isComplete: Bool
        switch listing {
        case .success(let listed):
            // What was read is counted, once; what wasn't makes the folder
            // a read error, so the total is visibly incomplete, whatever the
            // error was.
            entries = listed.entries
            isComplete = listed.isComplete
            if !listed.isComplete {
                unreadable.add(1, ordering: .relaxed)
            }
        case .failure(let error):
            failed(node, code: error.code.rawValue)
            return Kept(next: nil)
        }

        let visit = delegate.visit(VisitedDirectory(
            path: node.path, name: node.name, depth: node.depth,
            context: node.context, entries: entries, isComplete: isComplete))
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
                    skipped.add(1, ordering: .relaxed)
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
        /// The folder being listed, the last sign of progress (uptime ns),
        /// and the listing's lifecycle record.
        private let current = Mutex<(node: Node, since: UInt64, operation: ListingOperation)?>(nil)
        private let abandoned = Atomic<Bool>(false)

        var listing: (Node, UInt64, ListingOperation)? {
            current.withLock { $0.map { ($0.node, $0.since, $0.operation) } }
        }
        var isAbandoned: Bool { abandoned.load(ordering: .relaxed) }

        func begin(_ node: Node) -> ListingOperation {
            let operation = ListingOperation(path: node.path)
            current.withLock { $0 = (node, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), operation) }
            return operation
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

    /// Removes everything queued and hands each element to `body`, which
    /// must not push more work. Finishes the queue if no thread holds work.
    func drain(_ body: (Element) -> Void) {
        condition.lock()
        let pending = stack
        stack.removeAll()
        condition.unlock()
        pending.forEach(body)
        condition.lock()
        let idle = busy == 0 && stack.isEmpty
        if idle { finished = true }
        condition.unlock()
        if idle { condition.broadcast() }
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

    func removeAll() {
        for shard in shards { shard.inodes.withLock { $0 = [] } }
    }
}

/// A delegate that only sums sizes.
struct SizeOnly: WalkDelegate {
    func rootContext() {}
    func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, Never> {
        Visit(mark: nil, childContext: ())
    }
}
