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
            stuckListings: StuckListings(limit: 32)
        ) { path, reader throws(POSIXError) in
            if (path as NSString).lastPathComponent.hasPrefix("blocked-") {
                entered.increment()
                gate.wait()
            }
            return try reader.entries(atPath: path)
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
        let budget = StuckListings(limit: 6)
        func walk() throws -> WalkResult<Never> {
            try Walker(
                root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.05,
                stuckListings: budget
            ) { path, reader throws(POSIXError) in
                if (path as NSString).lastPathComponent.hasPrefix("blocked-") {
                    entered.increment()
                    gate.wait()
                }
                return try reader.entries(atPath: path)
            }.run()
        }

        var enteredAfter: [Int] = []
        var rootErrors: [POSIXErrorCode?] = []
        for _ in 0..<5 {
            let result = try walk()
            enteredAfter.append(entered.count)
            rootErrors.append(result.rootError?.code)
        }
        // A walk only starts threads while the count is under the limit, but
        // each one it starts may block too: the bound is limit + threads - 1.
        let bound = budget.limit + 2 - 1
        #expect(enteredAfter.last! <= bound, "\(enteredAfter)")
        #expect(enteredAfter.suffix(3).allSatisfy { $0 == enteredAfter.last }, "\(enteredAfter)")
        #expect(budget.count <= bound)
        // At the limit a walk doesn't start: it reports its root unreadable
        // rather than adding a thread.
        #expect(rootErrors.last == .ETIMEDOUT, "\(rootErrors)")

        gate.open()
        let deadline = Date(timeIntervalSinceNow: 5)
        while budget.count > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(budget.count == 0)
        let recovered = try Walker(root: dir.path, delegate: SizeOnly(), stuckListings: budget).run()
        #expect(recovered.rootError == nil)
        #expect(recovered.readErrors == 0)
        #expect(recovered.items == 20)
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
                stuckListings: StuckListings(limit: 32)
            ) { path, reader throws(POSIXError) in
                if path == blocked { gate.wait() }
                return try reader.entries(atPath: path)
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
            stuckListings: StuckListings(limit: 32)
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
            return try reader.entries(atPath: path)
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
            stuckListings: StuckListings(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.entries(atPath: path)
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
            stuckListings: StuckListings(limit: 32)
        ) { path, reader throws(POSIXError) in
            if (path as NSString).lastPathComponent.hasPrefix("blocked-") { gate.wait() }
            return try reader.entries(atPath: path)
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
            stuckListings: StuckListings(limit: 32)
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.entries(atPath: path)
        }
        let result = try walker.run()
        #expect(result.stalled == [blocked])
        #expect(result.readErrors == 1)
        // Everything else was listed by the replacement thread.
        #expect(result.items == 1 + 20 * 3)
    }
}
