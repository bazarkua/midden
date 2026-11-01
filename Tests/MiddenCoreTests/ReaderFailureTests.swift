import Foundation
import Testing
@testable import MiddenCore

/// One getattrlistbulk record, built byte by byte the way the kernel packs
/// it, with chosen attributes left out or set to an error.
private struct FakeRecord {
    var name: String
    var type: UInt32 = VREG.rawValue
    var error: UInt32 = 0
    var allocated: Int64 = 4_096
    var linkCount: UInt32 = 1
    var modified = 1_700_000_000
    var inode: UInt64 = 42
    var omitModificationTime = false
    var omitAllocatedSize = false
    /// Overrides the record's length field.
    var length: UInt32?
    /// Points the name past the end of the record.
    var nameOutOfBounds = false

    func bytes() -> [UInt8] {
        var out: [UInt8] = []
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        var common = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(
            ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        if !omitModificationTime { common |= attrgroup_t(ATTR_CMN_MODTIME) }
        if error != 0 { common |= attrgroup_t(ATTR_CMN_ERROR) }
        let isDirectory = type == VDIR.rawValue
        var set = attribute_set_t()
        set.commonattr = common
        if isDirectory {
            set.dirattr = omitAllocatedSize ? 0 : attrgroup_t(ATTR_DIR_ALLOCSIZE)
        } else {
            set.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
                | (omitAllocatedSize ? 0 : attrgroup_t(ATTR_FILE_ALLOCSIZE))
        }
        put(UInt32(0))  // Length, filled in below.
        put(set)
        if error != 0 { put(error) }
        let nameReferenceOffset = out.count
        put(attrreference_t())  // Filled in below.
        put(Int32(1))  // Device.
        put(type)
        if !omitModificationTime { put(timespec(tv_sec: modified, tv_nsec: 0)) }
        put(inode)
        if isDirectory {
            if !omitAllocatedSize { put(allocated) }
        } else {
            put(linkCount)
            if !omitAllocatedSize { put(allocated) }
        }
        let nameOffset = out.count
        out.append(contentsOf: Array(name.utf8) + [0])
        while out.count % 8 != 0 { out.append(0) }
        let reference = attrreference_t(
            attr_dataoffset: Int32(nameOffset - nameReferenceOffset) + (nameOutOfBounds ? 4_096 : 0),
            attr_length: UInt32(name.utf8.count + 1))
        withUnsafeBytes(of: reference) { out.replaceSubrange(nameReferenceOffset..<nameReferenceOffset + 8, with: $0) }
        withUnsafeBytes(of: length ?? UInt32(out.count)) { out.replaceSubrange(0..<4, with: $0) }
        return out
    }
}

/// What each successive getattrlistbulk call returns.
private enum Batch {
    case records([FakeRecord])
    case error(Int32)
    /// The real call, on the real descriptor.
    case real
}

private final class Script {
    var batches: [Batch]
    var calls = 0
    /// Returned once the script runs out.
    var then: Batch
    init(_ batches: [Batch], then: Batch = .records([])) {
        self.batches = batches
        self.then = then
    }
}

private func scripted(_ reader: DirectoryReader, _ script: Script) {
    let system = DirectoryReader.Calls.system
    reader.calls.bulk = { fd, request, buffer in
        script.calls += 1
        let batch = script.batches.isEmpty ? script.then : script.batches.removeFirst()
        switch batch {
        case .error(let code):
            return (-1, code)
        case .real:
            return system.bulk(fd, request, buffer)
        case .records(let records):
            var offset = 0
            for record in records {
                let bytes = record.bytes()
                buffer.baseAddress!.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
                offset += bytes.count
            }
            return (Int32(records.count), 0)
        }
    }
}

private func withDirectory<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    try #require(fd >= 0)
    defer { close(fd) }
    return try body(fd)
}

@Suite struct ReaderFailureTests {
    @Test func retriesInterruptedCalls() throws {
        let dir = try TempDir()
        for index in 0..<30 { try dir.write("f\(index)", bytes: 100) }
        let reader = DirectoryReader()
        scripted(reader, Script([.error(EINTR), .error(EINTR)], then: .real))
        let listing = try withDirectory(dir.path) { try reader.listing(directory: $0) }
        #expect(listing.isComplete)
        #expect(listing.entries.count == 30)
    }

    @Test func endlessInterruptionsEndTheListing() throws {
        let reader = DirectoryReader()
        let script = Script([], then: .error(EINTR))
        scripted(reader, script)
        #expect(throws: POSIXError.self) {
            _ = try withDirectory("/") { try reader.listing(directory: $0) }
        }
        #expect(script.calls == DirectoryReader.interruptRetries + 1)
    }

    @Test func retriesOutOfMemoryAFewTimes() throws {
        let dir = try TempDir()
        try dir.write("only", bytes: 100)
        let recovering = DirectoryReader()
        scripted(recovering, Script([.error(ENOMEM), .error(ENOMEM)], then: .real))
        let listing = try withDirectory(dir.path) { try recovering.listing(directory: $0) }
        #expect(listing.isComplete)
        #expect(listing.entries.map(\.name) == ["only"])

        let failing = DirectoryReader()
        let script = Script([.records([FakeRecord(name: "seen")])], then: .error(ENOMEM))
        scripted(failing, script)
        let partial = try withDirectory(dir.path) { try failing.listing(directory: $0) }
        #expect(partial.error?.code == .ENOMEM)
        #expect(partial.entries.map(\.name) == ["seen"])
        #expect(script.calls == 1 + DirectoryReader.memoryRetries + 1)
    }

    @Test func aFailureBeforeAnyBatchThrows() throws {
        let reader = DirectoryReader()
        scripted(reader, Script([.error(EACCES)]))
        #expect(throws: POSIXError(.EACCES)) {
            _ = try withDirectory("/") { try reader.listing(directory: $0) }
        }
    }

    /// The listing used to be all or nothing: a failure after some batches
    /// dropped what had been read. Now it's kept and marked incomplete.
    @Test func aFailureAfterABatchKeepsWhatWasRead() throws {
        let dir = try TempDir()
        for index in 0..<200 { try dir.write("file-\(index)", bytes: 100) }
        let reader = DirectoryReader(bufferSize: 4_096)
        scripted(reader, Script([.real, .error(EIO)]))
        let listing = try withDirectory(dir.path) { try reader.listing(directory: $0) }
        #expect(listing.error?.code == .EIO)
        #expect(!listing.entries.isEmpty && listing.entries.count < 200)
        #expect(Set(listing.entries.map(\.name)).count == listing.entries.count)
        // The strict form used by the cleaner refuses it.
        let strict = DirectoryReader(bufferSize: 4_096)
        scripted(strict, Script([.real, .error(EIO)]))
        #expect(throws: POSIXError(.EIO)) {
            _ = try withDirectory(dir.path) { try strict.entries(directory: $0) }
        }
    }

    /// errno must be read before the progress callback runs, or a callback
    /// that touches errno changes which error is reported.
    @Test func reportsTheErrorOfTheCallNotOfTheCallback() throws {
        let dir = try TempDir()
        let file = try dir.write("plain.txt", bytes: 10)
        let fd = open(file, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let reader = DirectoryReader()
        reader.onBatch = { errno = EPERM }
        do {
            _ = try reader.entries(directory: fd)
            Issue.record("listing a regular file succeeded")
        } catch {
            #expect(error.code != .EPERM)
            #expect(error.code == .ENOTDIR)
        }
    }

    @Test func anEntryWithAnErrorMakesTheListingIncomplete() throws {
        let reader = DirectoryReader()
        scripted(reader, Script([.records([
            FakeRecord(name: "a"), FakeRecord(name: "b", error: UInt32(EACCES)), FakeRecord(name: "c"),
        ])]))
        let listing = try withDirectory("/") { try reader.listing(directory: $0) }
        #expect(listing.entries.map(\.name) == ["a", "c"])
        #expect(listing.error?.code == .EACCES)
    }

    /// A zero modification time read as "idle for 56 years" would make a
    /// project's build folder Safe; a missing size would count as 0 bytes.
    @Test func anEntryWithoutRequiredAttributesIsLeftOutNotZeroed() throws {
        let reader = DirectoryReader()
        scripted(reader, Script([.records([
            FakeRecord(name: "complete"),
            FakeRecord(name: "no-mtime", omitModificationTime: true),
            FakeRecord(name: "no-size", omitAllocatedSize: true),
            FakeRecord(name: "dir-no-size", type: VDIR.rawValue, omitAllocatedSize: true),
            FakeRecord(name: "dir", type: VDIR.rawValue, allocated: 0),
        ])]))
        let listing = try withDirectory("/") { try reader.listing(directory: $0) }
        #expect(listing.entries.map(\.name) == ["complete", "dir"])
        #expect(listing.error?.code == .ENOATTR)
        #expect(listing.entries.allSatisfy { $0.modified > 0 })
    }

    @Test func malformedRecordsStopTheBatchWithoutCrashing() throws {
        for bad in [
            FakeRecord(name: "zero", length: 0),
            FakeRecord(name: "huge", length: 1 << 30),
            FakeRecord(name: "name-outside", nameOutOfBounds: true),
        ] {
            let reader = DirectoryReader(bufferSize: 8_192)
            scripted(reader, Script([.records([FakeRecord(name: "good"), bad, FakeRecord(name: "after")])]))
            let listing = try withDirectory("/") { try reader.listing(directory: $0) }
            #expect(listing.entries.first?.name == "good", "\(bad.name)")
            #expect(!listing.entries.contains { $0.name == bad.name }, "\(bad.name)")
            #expect(listing.error != nil, "\(bad.name)")
        }
    }

    @Test func readdirFallbackReportsErrorsInsteadOfStoppingQuietly() throws {
        let dir = try TempDir()
        for name in ["a", "b", "c", "gone", "locked"] { try dir.write(name, bytes: 10) }

        // readdir ends with an error after two entries.
        let cutShort = DirectoryReader()
        var served = 0
        let system = DirectoryReader.Calls.system
        cutShort.calls.readdir = { dir in
            served += 1
            return served <= 2 ? system.readdir(dir) : (nil, EIO)
        }
        let short = try withDirectory(dir.path) { try cutShort.readdirListing(directory: $0) }
        #expect(short.error?.code == .EIO)

        // An entry that vanished is left out quietly; one that can't be
        // read makes the listing incomplete.
        let picky = DirectoryReader()
        picky.calls.fstatat = { fd, name, info in
            switch name {
            case "gone": ENOENT
            case "locked": EACCES
            default: system.fstatat(fd, name, &info)
            }
        }
        let listing = try withDirectory(dir.path) { try picky.readdirListing(directory: $0) }
        #expect(Set(listing.entries.map(\.name)) == ["a", "b", "c"])
        #expect(listing.error?.code == .EACCES)

        let vanished = DirectoryReader()
        vanished.calls.fstatat = { fd, name, info in name == "gone" ? ENOENT : system.fstatat(fd, name, &info) }
        let clean = try withDirectory(dir.path) { try vanished.readdirListing(directory: $0) }
        #expect(clean.isComplete)
        #expect(clean.entries.count == 4)
    }

    /// The fallback used to report no progress until it finished, so the
    /// watchdog would give up a large folder that was still being read.
    @Test func readdirFallbackBeatsWhileReading() throws {
        let dir = try TempDir()
        for index in 0..<1_000 { try dir.write("f\(index)") }
        let reader = DirectoryReader()
        var beats = 0
        reader.onBatch = { beats += 1 }
        let listing = try withDirectory(dir.path) { try reader.readdirListing(directory: $0) }
        #expect(listing.entries.count == 1_000)
        #expect(beats >= 1_000 / DirectoryReader.fallbackBatch)
    }
}

@Suite struct PartialListingWalkTests {
    /// Cuts the listing of `path` to its first `keep` entries, as a read
    /// that failed partway would.
    private func cutting(_ path: String, keep: Int) -> Walker<ScanDelegate>.Lister {
        { listed, reader throws(POSIXError) in
            var listing = try reader.listing(atPath: listed)
            if listed == path {
                listing.entries = Array(listing.entries.sorted { $0.name < $1.name }.prefix(keep))
                listing.error = POSIXError(.EIO)
            }
            return listing
        }
    }

    @Test func entriesReadBeforeAFailureAreCountedOnce() throws {
        let dir = try TempDir()
        for index in 0..<10 { try dir.write("partial/f\(index)", bytes: 10_000) }
        try dir.write("other/g", bytes: 10_000)
        let walker = Walker(root: dir.path, delegate: SizeOnly()) { listed, reader throws(POSIXError) in
            var listing = try reader.listing(atPath: listed)
            if listed.hasSuffix("/partial") {
                listing.entries = Array(listing.entries.sorted { $0.name < $1.name }.prefix(4))
                listing.error = POSIXError(.EIO)
            }
            return listing
        }
        let result = try walker.run()
        #expect(result.readErrors == 1)
        // partial, other, g, and the 4 entries that were read.
        #expect(result.items == 7)
        let fileBytes = Int64(12_288)  // 10,000 bytes in 4 KB blocks.
        #expect(result.totalBytes == 5 * fileBytes)
    }

    /// A project whose listing came back incomplete may be missing exactly
    /// the newer file that shows it's in use: nothing in it is classified.
    @Test func nothingInsideAnIncompleteListingIsClassified() throws {
        let home = try TempDir("home")
        try home.write("code/app/package.json", text: "{}")
        try home.write("code/app/node_modules/dep/index.js", bytes: 1_000)
        try home.touch("code/app/package.json", daysAgo: 30)
        let complete = try Walker(root: home.path, delegate: ScanDelegate()).run()
        #expect(complete.marked.contains { $0.path == home.path("code/app/node_modules") })

        let incomplete = try Walker(
            root: home.path, delegate: ScanDelegate(), lister: cutting(home.path("code/app"), keep: 2)
        ).run()
        #expect(incomplete.readErrors == 1)
        #expect(incomplete.marked.isEmpty)
    }
}
