import Foundation
import Testing
@testable import MiddenCore

@Suite struct DirectoryReaderTests {
    /// The reference: readdir(3) plus lstat(2) for every entry.
    private func lstatListing(_ path: String) throws -> [String: DirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0)
        defer { close(fd) }
        let entries = try DirectoryReader.readdirEntries(directory: fd)
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    }

    @Test func matchesLstat() throws {
        let dir = try TempDir()
        try dir.write("plain.txt", bytes: 10_000)
        try dir.write("empty")
        try dir.write("café.txt", text: "accent")
        try dir.write("日本語 📦.bin", bytes: 5_000)
        try dir.mkdir("folder")
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("link"), withDestinationPath: "plain.txt")
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("dangling"), withDestinationPath: "nowhere")
        // A sparse file: 2 GB long, a few bytes allocated.
        let sparse = try dir.write("sparse.img")
        let handle = try #require(FileHandle(forWritingAtPath: sparse))
        try handle.truncate(atOffset: 2_000_000_000)
        try handle.seek(toOffset: 1_999_999_000)
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()

        let reader = DirectoryReader()
        let entries = try reader.entries(atPath: dir.path)
        let expected = try lstatListing(dir.path)

        #expect(Set(entries.map(\.name)) == Set(expected.keys))
        #expect(entries.count == 8)
        for entry in entries {
            let reference = try #require(expected[entry.name])
            #expect(entry.kind == reference.kind, "\(entry.name)")
            #expect(entry.inode == reference.inode, "\(entry.name)")
            #expect(entry.device == reference.device, "\(entry.name)")
            #expect(Int64(entry.modified) == Int64(reference.modified), "\(entry.name)")
            if entry.kind != .directory {
                #expect(entry.allocatedSize == reference.allocatedSize, "\(entry.name)")
                #expect(entry.linkCount == reference.linkCount, "\(entry.name)")
            }
        }
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.kind) })
        #expect(kinds["link"] == .symlink)
        #expect(kinds["dangling"] == .symlink)
        #expect(kinds["folder"] == .directory)
        #expect(kinds["empty"] == .file)

        let sparseEntry = try #require(entries.first { $0.name == "sparse.img" })
        #expect(sparseEntry.allocatedSize < 1_000_000)
        let emptyEntry = try #require(entries.first { $0.name == "empty" })
        #expect(emptyEntry.allocatedSize == 0)
    }

    @Test func readsLargeDirectoriesInSeveralCalls() throws {
        let dir = try TempDir()
        for index in 0..<1_200 {
            try dir.write("entry-\(index)", bytes: index % 3)
        }
        // A small buffer forces many calls; the default size must agree with it.
        let small = DirectoryReader(bufferSize: 4_096)
        let entries = try small.entries(atPath: dir.path)
        #expect(small.bulkCalls > 3)
        #expect(entries.count == 1_200)
        #expect(Set(entries.map(\.name)).count == 1_200)

        let regular = try DirectoryReader().entries(atPath: dir.path)
        #expect(Set(regular.map(\.name)) == Set(entries.map(\.name)))
        let expected = try lstatListing(dir.path)
        for entry in entries {
            #expect(entry.allocatedSize == expected[entry.name]?.allocatedSize)
        }
    }

    @Test func countsHardLinks() throws {
        let dir = try TempDir()
        let original = try dir.write("original", bytes: 8_192)
        try FileManager.default.linkItem(atPath: original, toPath: dir.path("link"))
        let entries = try DirectoryReader().entries(atPath: dir.path)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.linkCount == 2 })
        #expect(entries[0].inode == entries[1].inode)
    }

    @Test func refusesSymlinkedDirectory() throws {
        let dir = try TempDir()
        try dir.mkdir("real")
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("alias"), withDestinationPath: "real")
        #expect(throws: POSIXError.self) {
            try DirectoryReader().entries(atPath: dir.path("alias"))
        }
    }
}
