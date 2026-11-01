import Foundation
import Synchronization
import Testing
@testable import MiddenCore

private final class Counter: Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.add(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

/// Lets blocked listings go, once, however many are waiting.
private final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let opened = Atomic<Bool>(false)
    func wait() {
        if opened.load(ordering: .acquiring) { return }
        semaphore.wait()
        semaphore.signal()  // Pass it on to the next waiter.
    }
    func open() {
        if !opened.exchange(true, ordering: .acquiringAndReleasing) { semaphore.signal() }
    }
}

private func duBytes(_ path: String) throws -> Int64 {
    let output = try sh(["du", "-sk", path])
    return try #require(Int64(output.split(separator: "\t").first ?? "")) * 1024
}

/// Marks every directory, so the walk collects one record per folder.
private struct MarkAll: WalkDelegate {
    func rootContext() {}
    func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, String> {
        Visit(mark: directory.name, childContext: ())
    }
}

private final class WeakRecord {
    weak var value: SizedDirectory<String>?
    init(_ value: SizedDirectory<String>) { self.value = value }
}

@Suite struct WatchdogTests {
    /// Every folder the watchdog gives up leaves a thread blocked in the
    /// kernel, and the walker used to start a replacement for each one
    /// without limit: 40 blocked folders left 40 threads behind, and every
    /// new scan of the same folders would leave 40 more.
    @Test func boundsTheThreadsBlockedListingsLeaveBehind() throws {
        let dir = try TempDir()
        let blockedCount = 40
        for index in 0..<blockedCount {
            try dir.write("blocked-\(index)/file.bin", bytes: 1_000)
        }
        let gate = Gate()
        defer { gate.open() }
        let entered = Counter()
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.05,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if (path as NSString).lastPathComponent.hasPrefix("blocked-") {
                entered.increment()
                gate.wait()
            }
            return try reader.listing(atPath: path)
        }

        let start = Date()
        let result = try walker.run()
        #expect(Date().timeIntervalSince(start) < 10)
        // At most the pool plus one replacement per thread got stuck.
        #expect(entered.count <= 4, "\(entered.count) threads blocked")
        // Folders nobody could list are still accounted for, not dropped.
        #expect(result.readErrors == blockedCount)
        #expect(result.rootError == nil)
        #expect(result.items == Int64(blockedCount))
    }

    /// The same blocked folders, scanned again and again: the number of
    /// stuck threads stops at the process-wide limit, and recovers once the
    /// blocked calls return.
    @Test func repeatedScansStopAddingStuckThreads() throws {
        let dir = try TempDir()
        for index in 0..<10 {
            try dir.write("blocked-\(index)/file.bin", bytes: 1_000)
        }
        let gate = Gate()
        defer { gate.open() }
        let entered = Counter()
        let budget = WalkerThreads(limit: 6)
        func walk() throws -> WalkResult<Never> {
            try Walker(
                root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.05,
                threads: budget
            ) { path, reader throws(POSIXError) in
                if (path as NSString).lastPathComponent.hasPrefix("blocked-") {
                    entered.increment()
                    gate.wait()
                }
                return try reader.listing(atPath: path)
            }.run()
        }

        var enteredAfter: [Int] = []
        var rootErrors: [POSIXErrorCode?] = []
        for _ in 0..<5 {
            let result = try walk()
            enteredAfter.append(entered.count)
            rootErrors.append(result.rootError?.code)
        }
        // Each thread holds a slot until it really exits, so stuck threads
        // never exceed the limit, however many walks run.
        #expect(enteredAfter.last! <= budget.limit, "\(enteredAfter)")
        #expect(enteredAfter.suffix(3).allSatisfy { $0 == enteredAfter.last }, "\(enteredAfter)")
        #expect(budget.highWater <= budget.limit)
        // With every slot held by a stuck thread, a walk doesn't start: it
        // reports its root unreadable rather than adding a thread.
        #expect(rootErrors.last == .ETIMEDOUT, "\(rootErrors)")

        gate.open()
        let deadline = Date(timeIntervalSinceNow: 5)
        while budget.held > 0 || budget.abandonedCount > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(budget.held == 0)
        #expect(budget.abandonedCount == 0)
        let recovered = try Walker(root: dir.path, delegate: SizeOnly(), threads: budget).run()
        #expect(recovered.rootError == nil)
        #expect(recovered.readErrors == 0)
        #expect(recovered.items == 20)
    }

    /// Walks running at the same time share the budget: they can't all see
    /// a free slot and start threads past it.
    @Test func concurrentWalksShareATinyBudget() throws {
        let dir = try TempDir()
        for index in 0..<8 {
            try dir.write("blocked-\(index)/file.bin", bytes: 1_000)
        }
        let gate = Gate()
        defer { gate.open() }
        let budget = WalkerThreads(limit: 3)
        let entered = Counter()
        let root = dir.path
        let finished = Counter()
        for _ in 0..<4 {
            Thread {
                _ = try? Walker(
                    root: root, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.05, threads: budget
                ) { path, reader throws(POSIXError) in
                    if (path as NSString).lastPathComponent.hasPrefix("blocked-") {
                        entered.increment()
                        gate.wait()
                    }
                    return try reader.listing(atPath: path)
                }.run()
                finished.increment()
            }.start()
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while finished.count < 4, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(finished.count == 4, "walks didn't finish")
        #expect(budget.highWater <= 3)
        #expect(entered.count <= 3, "\(entered.count) listings blocked")

        gate.open()
        let drained = Date(timeIntervalSinceNow: 5)
        while budget.held > 0, Date() < drained { Thread.sleep(forTimeInterval: 0.01) }
        #expect(budget.held == 0)
    }

    /// Slots held by other walks' running threads come back as soon as
    /// those walks finish: a walk that finds none free waits for one
    /// instead of reporting its root unreadable.
    @Test func busyButHealthyWalksDontStarveEachOther() throws {
        let dir = try TempDir()
        for index in 0..<6 {
            try dir.write("folder-\(index)/file.bin", bytes: 1_000)
        }
        let budget = WalkerThreads(limit: 2)
        let root = dir.path
        let errors = Counter()
        let finished = Counter()
        for _ in 0..<6 {
            Thread {
                let result = try? Walker(
                    root: root, delegate: SizeOnly(), threadCount: 2, threads: budget
                ) { path, reader throws(POSIXError) in
                    usleep(20_000)  // Slow enough for the walks to overlap.
                    return try reader.listing(atPath: path)
                }.run()
                if result?.rootError != nil || result?.readErrors != 0 { errors.increment() }
                finished.increment()
            }.start()
        }
        let deadline = Date(timeIntervalSinceNow: 20)
        while finished.count < 6, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(finished.count == 6)
        #expect(errors.count == 0, "\(errors.count) walks couldn't start")
        #expect(budget.highWater <= 2)
    }

    /// Every slot is held by another walk's stuck thread. A walk waiting
    /// for a slot, with a 60-second stall timeout, returns as soon as it's
    /// cancelled: it lists nothing, takes no slot and frees none of the
    /// held ones. One cancelled before it starts doesn't wait at all.
    @Test func cancellingAWalkWaitingForASlotReturnsPromptly() throws {
        let dir = try TempDir()
        try dir.write("blocked/file.bin", bytes: 1_000)
        let blocked = dir.path("blocked")
        let gate = Gate()
        defer { gate.open() }
        let budget = WalkerThreads(limit: 1)
        // Walk A: its only thread blocks, is given up, and keeps the slot.
        let first = try Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 1, stallTimeout: 0.05, threads: budget
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.listing(atPath: path)
        }.run()
        #expect(first.stalled == [blocked])
        #expect(budget.held == 1)

        let listed = Counter()
        let root = dir.path
        let waitingWalk: @Sendable (CancellationFlag) -> Walker<SizeOnly> = { _ in
            Walker(root: root, delegate: SizeOnly(), threadCount: 2, stallTimeout: 60, threads: budget) {
                path, reader throws(POSIXError) in
                listed.increment()
                return try reader.listing(atPath: path)
            }
        }

        // Walk B waits for admission; cancel it once it does.
        let flag = CancellationFlag()
        let outcome = Mutex<(result: WalkResult<Never>?, returned: Date?)>((nil, nil))
        Thread {
            let result = try? waitingWalk(flag).run(cancellation: flag)
            outcome.withLock { $0 = (result, Date()) }
        }.start()
        let waitDeadline = Date(timeIntervalSinceNow: 5)
        while budget.waiting == 0, Date() < waitDeadline { Thread.sleep(forTimeInterval: 0.005) }
        try #require(budget.waiting == 1, "the walk never waited for a slot")
        let cancelled = Date()
        flag.cancel()
        let returnDeadline = Date(timeIntervalSinceNow: 5)
        while outcome.withLock({ $0.returned }) == nil, Date() < returnDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let (result, returned) = outcome.withLock { $0 }
        let elapsed = try #require(returned, "the cancelled walk didn't return").timeIntervalSince(cancelled)
        #expect(elapsed < 0.5, "\(elapsed) s after cancel")
        #expect(result?.cancelled == true)
        #expect(result?.rootError == nil)
        #expect(result?.readErrors == 0)

        // Walk C: cancelled before it starts.
        let already = CancellationFlag()
        already.cancel()
        let started = Date()
        let early = try waitingWalk(already).run(cancellation: already)
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(early.cancelled)
        #expect(early.rootError == nil)

        #expect(listed.count == 0)
        #expect(budget.held == 1)
        #expect(budget.waiting == 0)
        gate.open()
        let drained = Date(timeIntervalSinceNow: 5)
        while budget.held > 0, Date() < drained { Thread.sleep(forTimeInterval: 0.01) }
        #expect(budget.held == 0)
    }

    /// The listing returns in the gap between the watchdog giving it up and
    /// registering it as abandoned. It must not stay registered: that would
    /// make every later scan skip a folder that reads fine.
    @Test func aListingThatReturnsWhileBeingGivenUpIsNotLeftRegistered() throws {
        let dir = try TempDir()
        try dir.write("slow/file.bin", bytes: 1_000)
        let slow = dir.path("slow")
        let gate = Gate()
        defer { gate.open() }
        let visits = Counter()
        let budget = WalkerThreads(limit: 8)
        let lister: Walker<SizeOnly>.Lister = { path, reader throws(POSIXError) in
            if path == slow {
                visits.increment()
                gate.wait()
            }
            return try reader.listing(atPath: path)
        }
        let first = try Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 1, stallTimeout: 0.1, threads: budget,
            lister: lister,
            afterGivingUp: { operation in
                // Let the call return now, and wait until it has.
                gate.open()
                let deadline = Date(timeIntervalSinceNow: 5)
                while !operation.isReturned, Date() < deadline { usleep(1_000) }
            }
        ).run()
        #expect(first.stalled == [slow])
        #expect(budget.abandonedCount == 0)
        #expect(!budget.isAbandoned(slow))

        let second = try Walker(root: dir.path, delegate: SizeOnly(), threads: budget, lister: lister).run()
        #expect(visits.count == 2, "the next scan didn't visit the folder")
        #expect(second.readErrors == 0)
        #expect(second.stalled.isEmpty)
    }

    /// The scan's own delegate collects every large file and repository it
    /// sees. A stuck thread keeps the walker, and so the delegate, alive:
    /// once the scan has taken what it collected, nothing may be left there.
    @Test func aStuckThreadDoesNotKeepTheDelegatesCollections() throws {
        let home = try TempDir("home")
        try home.write("blocked/file.bin", bytes: 1_000)
        for index in 0..<5 {
            try home.write("Downloads/Setup-\(index).pkg", bytes: 100_000_000)
        }
        try home.mkdir("repo/.git/worktrees/wt")
        let blocked = home.path("blocked")
        let gate = Gate()
        defer { gate.open() }
        let delegate = ScanDelegate(skipProtected: false)
        let result = try Walker(
            root: home.path, delegate: delegate, threadCount: 2, stallTimeout: 0.1,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.listing(atPath: path)
        }.run()
        #expect(result.stalled == [blocked])

        let collected = delegate.takeCollected()
        #expect(collected.files.count == 5)
        #expect(collected.gitDirectories == [home.path("repo/.git")])
        // The blocked thread still holds the walker and the delegate here.
        #expect(delegate.files.isEmpty)
        #expect(delegate.gitDirectories.isEmpty)
        #expect(delegate.skippedFolders.isEmpty)
    }

    /// Each timed-out probe leaves its thread running; repeated probes that
    /// all block must not pile up threads without limit.
    @Test func timedOutProbesDontPileUpThreads() {
        let gate = Gate()
        defer { gate.open() }
        let threads = DeadlineThreads(limit: 2)
        let started = Counter()
        for _ in 0..<6 {
            let answer = System.withDeadline(0.05, threads: threads) { () -> Bool in
                started.increment()
                gate.wait()
                return true
            }
            #expect(answer == nil)
        }
        #expect(started.count == 2)
        #expect(threads.count == 2)

        gate.open()
        let deadline = Date(timeIntervalSinceNow: 5)
        while threads.count > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(threads.count == 0)
        #expect(System.withDeadline(1, threads: threads) { true } == true)
    }

    /// A stuck thread references the walker. It must not keep everything
    /// the walk collected alive until its call returns, which may be never.
    @Test func aStuckThreadDoesNotKeepTheScanAlive() throws {
        let dir = try TempDir()
        try dir.write("blocked/file.bin", bytes: 1_000)
        for index in 0..<30 {
            try dir.write("kept-\(index)/inner/file.bin", bytes: 1_000)
        }
        let blocked = dir.path("blocked")
        let gate = Gate()
        defer { gate.open() }
        var records: [WeakRecord] = []
        do {
            let result = try Walker(
                root: dir.path, delegate: MarkAll(), threadCount: 2, stallTimeout: 0.1,
                threads: WalkerThreads(limit: 32)
            ) { path, reader throws(POSIXError) in
                if path == blocked { gate.wait() }
                return try reader.listing(atPath: path)
            }.run()
            #expect(result.stalled == [blocked])
            records = result.marked.filter { $0.path.hasPrefix(dir.path("kept-")) }.map(WeakRecord.init)
        }
        #expect(records.count == 60)
        // The blocked thread is still waiting at this point.
        #expect(records.allSatisfy { $0.value == nil }, "records outlived the walk")
    }

    /// A listing that returns after the watchdog gave it up must not add
    /// its entries or finish its parent's countdown a second time.
    @Test func aLateReturnIsDropped() throws {
        let dir = try TempDir()
        try dir.write("blocked/a.bin", bytes: 300_000)
        try dir.write("blocked/inner/b.bin", bytes: 200_000)
        try dir.write("slow/c.bin", bytes: 100_000)
        try dir.write("fine/d.bin", bytes: 50_000)
        let blocked = dir.path("blocked")
        let slow = dir.path("slow")
        let gate = Gate()
        defer { gate.open() }
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.15,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            if path == slow {
                // Still going, and beating, when the blocked call returns.
                for step in 0..<10 {
                    Thread.sleep(forTimeInterval: 0.08)
                    if step == 5 { gate.open() }
                    reader.onBatch?()
                }
            }
            return try reader.listing(atPath: path)
        }
        let result = try walker.run()
        #expect(result.stalled == [blocked])
        #expect(result.readErrors == 1)
        #expect(result.totalBytes == (try duBytes(dir.path)) - (try duBytes(blocked)))
        // blocked, slow, fine, c.bin, d.bin: nothing from inside `blocked`.
        #expect(result.items == 5)
    }

    /// A hard link inside a folder that was given up must not use up the
    /// inode, or the same file's other name would vanish from the totals.
    @Test func aGivenUpFolderDoesNotHideAHardLinkElsewhere() throws {
        let dir = try TempDir()
        let original = try dir.write("blocked/data.bin", bytes: 2_000_000)
        try dir.mkdir("fine")
        try FileManager.default.linkItem(atPath: original, toPath: dir.path("fine/alias.bin"))
        let blocked = dir.path("blocked")
        let gate = Gate()
        defer { gate.open() }
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.1,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.listing(atPath: path)
        }
        let result = try walker.run()
        #expect(result.stalled == [blocked])
        var info = stat()
        #expect(lstat(original, &info) == 0)
        let fileBytes = Int64(info.st_blocks) * 512
        // du counts the file once, inside `blocked`; the walk must count it
        // once too, under `fine`.
        #expect(result.totalBytes == (try duBytes(dir.path)) - (try duBytes(blocked)) + fileBytes)
    }

    /// Cancelling doesn't wait out the stall timeout, even when every
    /// thread is blocked: the walk returns within one supervisor tick.
    @Test func cancellingReturnsWithinATickWhenEveryThreadIsBlocked() throws {
        let dir = try TempDir()
        for index in 0..<4 {
            try dir.write("blocked-\(index)/file.bin", bytes: 1_000)
        }
        let gate = Gate()
        defer { gate.open() }
        let flag = CancellationFlag()
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 60,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if (path as NSString).lastPathComponent.hasPrefix("blocked-") { gate.wait() }
            return try reader.listing(atPath: path)
        }
        // Its own thread: under a full test run GCD's pool can be busy.
        Thread {
            Thread.sleep(forTimeInterval: 0.3)
            flag.cancel()
        }.start()
        let start = Date()
        _ = try walker.run(cancellation: flag)
        // 0.3 s until cancel, then at most a 0.25 s tick.
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// The pool keeps working after a stuck folder while it has threads to spare.
    @Test func replacesAStuckThreadWhileUnderTheLimit() throws {
        let dir = try TempDir()
        try dir.write("blocked/file.bin", bytes: 1_000)
        for index in 0..<20 {
            try dir.write("fine-\(index)/sub/file.bin", bytes: 4_096)
        }
        let blocked = dir.path("blocked")
        let gate = Gate()
        defer { gate.open() }
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 1, stallTimeout: 0.1,
            threads: WalkerThreads(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.listing(atPath: path)
        }
        let result = try walker.run()
        #expect(result.stalled == [blocked])
        #expect(result.readErrors == 1)
        // Everything else was listed by the replacement thread.
        #expect(result.items == 1 + 20 * 3)
    }
}
