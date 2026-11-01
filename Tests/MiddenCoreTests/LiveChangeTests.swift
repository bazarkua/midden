import Foundation
import Synchronization
import Testing
@testable import MiddenCore

private final class Tally: Sendable {
    private let value = Atomic<Int>(0)
    func add() { value.add(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

private final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}

/// Changes a folder on its own thread until stopped.
private func churn(_ stop: StopFlag, _ body: @escaping @Sendable (inout UInt64) -> Void) -> Thread {
    let thread = Thread {
        var step: UInt64 = 0x2545_F491_4F6C_DD1D
        while !stop.isSet {
            step = step &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            body(&step)
        }
    }
    thread.start()
    return thread
}

/// Walks on another thread and fails the test instead of hanging.
private func walkWithDeadline(_ root: String, threads: Int = 4) throws -> WalkResult<Never> {
    let outcome = System.withDeadline(20) { () -> Result<WalkResult<Never>, POSIXError> in
        Result { () throws(POSIXError) in try Walker(root: root, delegate: SizeOnly(), threadCount: threads).run() }
    }
    let finished = try #require(outcome, "the walk didn't finish within 20 s")
    return try finished.get()
}

/// Open descriptors in this process.
private func openDescriptors() -> Int {
    (0..<Int(getdtablesize())).reduce(0) { count, fd in fcntl(Int32(fd), F_GETFD) != -1 ? count + 1 : count }
}

private let fileBytes = Int64(4_096)  // Each file below holds 1,000 bytes: one APFS block.

@Suite(.serialized) struct LiveChangeTests {
    /// A tree nothing touches, next to one that changes all the time:
    /// every walk finishes, counts the quiet part exactly, and stays within
    /// what the changing part could hold, counted at most twice (a folder
    /// renamed from a part not yet read to another can be seen twice).
    @Test func walksWhileFilesAndFoldersChange() throws {
        let dir = try TempDir()
        for folder in 0..<20 {
            for file in 0..<50 { try dir.write("quiet/q\(folder)/f\(file)", bytes: 1_000) }
        }
        let churnRoot = try dir.mkdir("churn")
        let slots = 40
        let maxEntries = Int64(slots * 3)  // A folder, a file in it, a renamed copy.
        let quiet = try walkWithDeadline(dir.path(""))
        let quietBytes = quiet.totalBytes
        let quietItems = quiet.items

        let stop = StopFlag()
        let changer = churn(stop) { step in
            let slot = Int(step >> 33) % slots
            let folder = churnRoot + "/s\(slot)"
            switch (step >> 20) % 6 {
            case 0:
                mkdir(folder, 0o755)
                FileManager.default.createFile(atPath: folder + "/f", contents: Data(repeating: 1, count: 1_000))
            case 1:
                unlink(folder + "/f")
                rmdir(folder)
            case 2:
                rename(folder + "/f", folder + "/g")
            case 3:
                rename(folder + "/g", folder + "/f")
            case 4:
                // Moves a folder to another slot, possibly one already read.
                rename(folder, churnRoot + "/s\((slot + 7) % slots)")
            default:
                unlink(folder + "/g")
            }
        }
        defer {
            stop.set()
            while !changer.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        }

        // Listing a changing folder takes a millisecond, so changes land
        // between a folder being seen in its parent and being opened.
        let vanished = Tally()
        let slowLister: Walker<SizeOnly>.Lister = { path, reader throws(POSIXError) in
            if path.hasPrefix(churnRoot + "/") { usleep(1_000) }
            do throws(POSIXError) {
                return try reader.listing(atPath: path)
            } catch {
                if error.code == .ENOENT { vanished.add() }
                throw error
            }
        }
        for round in 0..<20 {
            let walker = Walker(
                root: dir.path, delegate: SizeOnly(), threadCount: round % 2 == 0 ? 2 : 8, lister: slowLister)
            let outcome = System.withDeadline(20) { () -> Result<WalkResult<Never>, POSIXError> in
                Result { () throws(POSIXError) in try walker.run() }
            }
            let result = try #require(outcome, "the walk didn't finish within 20 s").get()
            #expect(result.rootError == nil)
            #expect(result.totalBytes >= quietBytes, "round \(round)")
            #expect(result.totalBytes <= quietBytes + 2 * maxEntries * fileBytes, "round \(round)")
            #expect(result.items >= quietItems, "round \(round)")
            #expect(result.items <= quietItems + 2 * maxEntries, "round \(round)")
        }
        // Folders did disappear between being listed and being opened.
        #expect(vanished.count > 0)
    }

    /// Folders become unreadable and readable again while walks run:
    /// a refused folder is a counted error, never a crash or a hang, and
    /// the folders nobody touches are counted exactly.
    @Test func walksWhilePermissionsChange() throws {
        let dir = try TempDir()
        for folder in 0..<10 {
            for file in 0..<30 { try dir.write("quiet/q\(folder)/f\(file)", bytes: 1_000) }
            for file in 0..<30 { try dir.write("flipping/p\(folder)/inner/f\(file)", bytes: 1_000) }
        }
        let quietOnly = try Walker(root: dir.path("quiet"), delegate: SizeOnly()).run()
        let flipping = (0..<10).flatMap { [dir.path("flipping/p\($0)"), dir.path("flipping/p\($0)/inner")] }
        defer { for folder in flipping { chmod(folder, 0o755) } }

        let stop = StopFlag()
        let changer = churn(stop) { step in
            let folder = flipping[Int(step >> 33) % flipping.count]
            chmod(folder, (step >> 20) % 2 == 0 ? 0o000 : 0o755)
        }
        defer {
            stop.set()
            while !changer.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        }

        var sawErrors = false
        for _ in 0..<20 {
            let result = try walkWithDeadline(dir.path)
            #expect(result.rootError == nil)
            sawErrors = sawErrors || result.readErrors > 0
            let quiet = try #require(result.root?.children.first { $0.name == "quiet" })
            #expect(quiet.bytes == quietOnly.totalBytes)
        }
        // The flips did land on walks in progress at least once.
        #expect(sawErrors)
    }

    /// Walks, listings, metadata reads and commands that fail in every way
    /// these tests know must not leave descriptors open. A leak would grow
    /// by one or more per round; other tests running at the same time move
    /// the count by a few at most.
    @Test func failuresLeaveNoDescriptorsOpen() throws {
        let dir = try TempDir()
        try dir.write("open/file", bytes: 100)
        try dir.write("locked/secret", bytes: 100)
        chmod(dir.path("locked"), 0o000)
        defer { chmod(dir.path("locked"), 0o755) }
        try #require(mkfifo(dir.path("fifo"), 0o644) == 0)
        for index in 0..<2_000 { try dir.write("long/f\(index)") }
        let long = dir.path("long")

        let before = openDescriptors()
        for _ in 0..<100 {
            _ = try Walker(root: dir.path, delegate: SizeOnly(), threadCount: 2).run()
            // A listing that fails after its first batch.
            let reader = DirectoryReader(bufferSize: 4_096)
            var calls = 0
            let system = DirectoryReader.Calls.system
            reader.calls.bulk = { fd, request, buffer in
                calls += 1
                return calls == 1 ? system.bulk(fd, request, buffer) : (-1, EIO)
            }
            _ = try? reader.listing(atPath: long)
            _ = try? reader.entries(atPath: dir.path("locked"))
            _ = try? reader.entries(atPath: dir.path("missing"))
            _ = try? reader.entries(atPath: dir.path("open/file"))
            _ = Classifier.readSmallFile(dir.path("fifo"))
            _ = Classifier.readSmallFile(dir.path("open"))
            _ = WorktreeAuditor.lastReflogTime(dir.path("fifo"))
            _ = Command.run(["/bin/sh", "-c", "exit 3"])
            _ = Command.run([dir.path("missing-tool")])
        }
        let after = openDescriptors()
        #expect(after - before < 20, "\(before) descriptors before, \(after) after")
    }
}
