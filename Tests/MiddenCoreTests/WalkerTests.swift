import Foundation
import Testing
@testable import MiddenCore

/// Marks every directory with the given name.
private struct MarkNamed: WalkDelegate {
    var names: Set<String>
    func rootContext() {}
    func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, String> {
        Visit(mark: names.contains(directory.name) ? directory.name : nil, childContext: ())
    }
}

private func duBytes(_ path: String) throws -> Int64 {
    let output = try sh(["du", "-sk", path])
    let kilobytes = try #require(Int64(output.split(separator: "\t").first ?? ""))
    return kilobytes * 1024
}

@Suite struct WalkerTests {
    /// A tree with nested folders, many small files, an empty folder and a
    /// sparse file.
    private func makeTree(_ dir: TempDir) throws {
        for project in 0..<5 {
            for module in 0..<8 {
                for file in 0..<12 {
                    try dir.write("p\(project)/m\(module)/f\(file).dat", bytes: (file + 1) * 3_000)
                }
            }
        }
        try dir.mkdir("empty/deeper/still")
        try dir.write("big/one.bin", bytes: 3_000_000)
        let sparse = try dir.write("big/sparse.img")
        let handle = try #require(FileHandle(forWritingAtPath: sparse))
        try handle.truncate(atOffset: 500_000_000)
        try handle.close()
    }

    @Test func totalMatchesDu() throws {
        let dir = try TempDir()
        try makeTree(dir)
        for threads in [1, 3, 8] {
            let result = try Walker(root: dir.path, delegate: SizeOnly(), threadCount: threads).run()
            #expect(result.totalBytes == (try duBytes(dir.path)), "threads: \(threads)")
            #expect(result.items == 5 * 8 * 12 + 5 * 8 + 5 + 3 + 3)
            #expect(result.unreadable == 0)
        }
    }

    @Test func countsHardLinksOnce() throws {
        let dir = try TempDir()
        let original = try dir.write("releases/1.0.0/data.bin", bytes: 2_000_000)
        try dir.mkdir("releases/latest")
        try FileManager.default.linkItem(
            atPath: original, toPath: dir.path("releases/latest/data.bin"))
        try FileManager.default.linkItem(atPath: original, toPath: dir.path("elsewhere.bin"))

        let result = try Walker(root: dir.path, delegate: SizeOnly()).run()
        #expect(result.totalBytes == (try duBytes(dir.path)))
        #expect(result.totalBytes < 2 * 2_000_000)
        #expect(result.totalBytes >= 2_000_000)
    }

    @Test func doesNotFollowSymlinks() throws {
        let outside = try TempDir()
        try outside.write("huge.bin", bytes: 5_000_000)
        let dir = try TempDir()
        try dir.write("small.txt", bytes: 100)
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("link-to-dir"), withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("link-to-file"), withDestinationPath: outside.path("huge.bin"))

        let result = try Walker(root: dir.path, delegate: SizeOnly()).run()
        #expect(result.totalBytes == (try duBytes(dir.path)))
        #expect(result.totalBytes < 1_000_000)
    }

    @Test func sizesMarkedDirectoriesAndTheirChildren() throws {
        let dir = try TempDir()
        try makeTree(dir)
        try dir.write("p1/m2/node_modules/a/index.js", bytes: 40_000)
        try dir.write("p1/m2/node_modules/b/lib.js", bytes: 2_500_000)
        try dir.write("p1/m2/node_modules/package-lock.json", bytes: 1_200_000)
        try dir.write("p1/m2/node_modules/.small", bytes: 10)

        let result = try Walker(
            root: dir.path, delegate: MarkNamed(names: ["node_modules", "big"])
        ).run()
        #expect(result.marked.count == 2)
        let modules = try #require(result.marked.first { $0.mark == "node_modules" })
        #expect(modules.path == dir.path("p1/m2/node_modules"))
        #expect(modules.total == (try duBytes(modules.path)))
        let children = Dictionary(uniqueKeysWithValues: modules.children.map { ($0.name, $0) })
        #expect(children["a"]?.isDirectory == true)
        #expect(children["a"]?.bytes == (try duBytes(dir.path("p1/m2/node_modules/a"))))
        #expect(children["b"]?.bytes == (try duBytes(dir.path("p1/m2/node_modules/b"))))
        #expect(children["package-lock.json"]?.isDirectory == false)
        #expect(children[".small"] == nil)

        let root = try #require(result.root)
        #expect(root.total == result.totalBytes)
        let top = root.children.filter(\.isDirectory)
        #expect(Set(top.map(\.name)) == ["p0", "p1", "p2", "p3", "p4", "empty", "big"])
        #expect(top.reduce(0) { $0 + $1.bytes } <= result.totalBytes)
        for child in top {
            #expect(child.bytes == (try duBytes(dir.path(child.name))), "\(child.name)")
        }
    }

    @Test func countsUnreadableDirectories() throws {
        let dir = try TempDir()
        try dir.write("open/file", bytes: 10)
        try dir.write("locked/secret", bytes: 10)
        chmod(dir.path("locked"), 0o000)
        defer { chmod(dir.path("locked"), 0o755) }
        let result = try Walker(root: dir.path, delegate: SizeOnly()).run()
        #expect(result.unreadable == 1)
    }

    @Test func givesUpAListingThatBlocks() throws {
        let dir = try TempDir()
        try dir.write("fine/a.bin", bytes: 300_000)
        try dir.write("fine/deeper/b.bin", bytes: 200_000)
        try dir.write("blocked/c.bin", bytes: 500_000)
        try dir.write("blocked/inside/d.bin", bytes: 100_000)
        let blocked = dir.path("blocked")
        // Stands in for open() waiting on a privacy prompt nobody answers.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let walker = Walker(
            root: dir.path, delegate: SizeOnly(), threadCount: 2, stallTimeout: 0.3
        ) { path, reader throws(POSIXError) in
            if path == blocked { gate.wait() }
            return try reader.listing(atPath: path)
        }

        let start = Date()
        let result = try walker.run()
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(result.unreadable == 1)
        #expect(result.stalled == [blocked])
        #expect(result.rootError == nil)
        #expect(result.totalBytes == (try duBytes(dir.path)) - (try duBytes(blocked)))
        let children = Dictionary(uniqueKeysWithValues: (result.root?.children ?? []).map { ($0.name, $0.bytes) })
        #expect(children["fine"] == (try duBytes(dir.path("fine"))))
    }

    @Test func blockedRootIsAnError() throws {
        let dir = try TempDir()
        try dir.write("a.bin", bytes: 1_000)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let root = dir.path
        let walker = Walker(root: root, delegate: SizeOnly(), stallTimeout: 0.2) { path, reader throws(POSIXError) in
            if path == root { gate.wait() }
            return try reader.listing(atPath: path)
        }
        let result = try walker.run()
        #expect(result.rootError?.code == .ETIMEDOUT)
    }

    @Test func keepsASlowListingThatMakesProgress() throws {
        let dir = try TempDir()
        try dir.write("big/a.bin", bytes: 4_096)
        let big = dir.path("big")
        let walker = Walker(root: dir.path, delegate: SizeOnly(), stallTimeout: 0.3) { path, reader throws(POSIXError) in
            if path == big {
                // Slower than the timeout overall, but beating like a reader
                // working through a huge folder batch by batch.
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.1)
                    reader.onBatch?()
                }
            }
            return try reader.listing(atPath: path)
        }
        let result = try walker.run()
        #expect(result.stalled.isEmpty)
        #expect(result.unreadable == 0)
        #expect(result.totalBytes == (try duBytes(dir.path)))
    }

    @Test func stopsWhenCancelled() throws {
        let dir = try TempDir()
        try makeTree(dir)
        let flag = CancellationFlag()
        flag.cancel()
        let result = try Walker(root: dir.path, delegate: SizeOnly()).run(cancellation: flag)
        #expect(result.items == 0)
    }
}
