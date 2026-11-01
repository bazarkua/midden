import Foundation
import Testing
@testable import MiddenCore

/// Builds a chain of `depth` folders named `name` below `root`, with
/// descriptors (mkdirat/openat), since paths past PATH_MAX can't be created
/// by path. Writes `bytes` bytes into a file named `file` in every folder
/// whose depth is a multiple of `every`, and in the deepest one. Returns the
/// bytes allocated to everything it made, measured with fstat.
private func makeChain(
    _ root: String, depth: Int, name: String, every: Int = 50, bytes: Int = 50_000
) throws -> Int64 {
    var fd = open(root, O_RDONLY | O_DIRECTORY)
    try #require(fd >= 0)
    let data = [UInt8](repeating: 0x5A, count: bytes)
    var allocated: Int64 = 0
    var info = stat()
    for level in 1...depth {
        try #require(mkdirat(fd, name, 0o755) == 0)
        let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
        close(fd)
        try #require(next >= 0)
        fd = next
        if level % every == 0 || level == depth {
            let file = openat(fd, "file", O_WRONLY | O_CREAT, 0o644)
            try #require(file >= 0)
            _ = data.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
            fsync(file)
            fstat(file, &info)
            allocated += Int64(info.st_blocks) * 512
            close(file)
        }
        fstat(fd, &info)
        allocated += Int64(info.st_blocks) * 512
    }
    close(fd)
    lstat(root, &info)
    return allocated + Int64(info.st_blocks) * 512
}

/// Removes a chain made by `makeChain` from the top, one level at a time,
/// so no path gets long: `rm -rf` took about 100 s for 5,000 levels.
private func removeChain(_ root: String, name: String) {
    let child = root + "/" + name
    let parked = root + "/.parked"
    while true {
        unlink(child + "/file")
        if rename(child + "/" + name, parked) == 0 {
            rmdir(child)
            rename(parked, child)
        } else {
            rmdir(child)
            break
        }
    }
}

/// `find -x` walks with descriptors (fts), so it handles any path length.
/// `du` doesn't: on a 600-level chain it printed "File name too long",
/// reported 0 for the whole tree and exited 1.
private func findCount(_ path: String) throws -> Int64 {
    try #require(Int64(try sh(["sh", "-c", "find -x \"$0\" | wc -l", path]).trimmingCharacters(in: .whitespaces)))
}

@Suite struct DeepPathTests {
    /// The walker opened every folder by its full path, and open() fails
    /// with ENAMETOOLONG past PATH_MAX (1024 bytes): a chain 600 folders
    /// deep was cut off near depth 100 and counted as one read error, with
    /// everything below missing from the totals.
    @Test func walksPathsLongerThanPathMax() throws {
        let dir = try TempDir()
        defer { removeChain(dir.path, name: "deep-dir-") }
        // 600 × 10 bytes: past PATH_MAX (1024) and past 4096.
        let allocated = try makeChain(dir.path, depth: 600, name: "deep-dir-")
        let result = try Walker(root: dir.path, delegate: SizeOnly(), threadCount: 4).run()
        #expect(result.readErrors == 0)
        #expect(result.items == (try findCount(dir.path)) - 1)
        #expect(result.totalBytes == allocated)
    }

    /// Thousands of levels: no stack overflow when the chain of folder
    /// nodes is released, and still every byte counted. Slow, so it runs
    /// only with MIDDEN_STRESS=1: every call in a deep folder costs time in
    /// proportion to its depth on the test Mac, even mkdirat and openat with
    /// a one-component name. At 5,000 levels, making the chain took 88 s,
    /// the walk 25 s, `find -x` 34 s and removing it 5 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIDDEN_STRESS"] != nil))
    func walksAVeryDeepChain() throws {
        let dir = try TempDir()
        defer { removeChain(dir.path, name: "d") }
        let allocated = try makeChain(dir.path, depth: 5_000, name: "d", every: 500, bytes: 10_000)
        let result = try Walker(root: dir.path, delegate: SizeOnly(), threadCount: 2).run()
        #expect(result.readErrors == 0)
        #expect(result.items == (try findCount(dir.path)) - 1)
        #expect(result.totalBytes == allocated)
    }
}
