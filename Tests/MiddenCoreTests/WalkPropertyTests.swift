import Foundation
import Testing
@testable import MiddenCore

/// SplitMix64: small, fast, and the same sequence for the same seed on
/// every machine.
private struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// Builds a random tree from a seed: empty, small and sparse files; hard
/// links within and across folders; symlinks to files, to folders,
/// dangling and in loops; a chain 64 folders deep; names in NFC and NFD
/// forms, with spaces, quotes, newlines and leading dashes; optionally one
/// folder with 20,000 entries.
private struct RandomTree {
    var random: SeededRandom
    let root: String
    var files: [String] = []
    var folders: [String] = []
    var made = 0

    init(seed: UInt64, root: String) {
        random = SeededRandom(state: seed)
        self.root = root
    }

    private static let shapes = [
        "plain", "with space", "it's", "say \"hi\"", "line\nbreak", "-leading-dash", "--", "café",
        "cafe\u{301}", "日本語", "📦 box", "tab\tname", ".hidden", " lead space", "trailing ",
    ]

    mutating func name() -> String {
        made += 1
        // NFC and NFD forms of the same name are one name to APFS, so the
        // counter keeps every name unique within its folder.
        return Self.shapes[random.below(Self.shapes.count)] + "-\(made)"
    }

    mutating func writeFile(_ path: String) {
        let size: Int
        switch random.below(10) {
        case 0, 1: size = 0
        case 2...6: size = random.below(5_000) + 1
        case 7, 8: size = random.below(300_000) + 1
        default: size = 1_500_000
        }
        let data = Data(repeating: UInt8(random.below(255) + 1), count: size)
        FileManager.default.createFile(atPath: path, contents: data)
        files.append(path)
    }

    mutating func writeSparse(_ path: String) {
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        ftruncate(fd, off_t(random.below(1_000) + 1) * 1_000_000)
        let bytes: [UInt8] = [1, 2, 3]
        _ = pwrite(fd, bytes, 3, off_t(random.below(500_000)))
        close(fd)
        files.append(path)
    }

    mutating func fill(_ folder: String, depth: Int) {
        folders.append(folder)
        let count = depth < 3 ? random.below(10) + 10 : random.below(6) + 1
        for _ in 0..<count {
            let path = folder + "/" + name()
            switch random.below(100) {
            case 0..<45:
                writeFile(path)
            case 45..<50:
                writeSparse(path)
            case 50..<72 where depth < 5:
                mkdir(path, 0o755)
                fill(path, depth: depth + 1)
            case 70..<80 where !files.isEmpty:
                link(files[random.below(files.count)], path)
            case 80..<85 where !files.isEmpty:
                symlink(files[random.below(files.count)], path)
            case 85..<88:
                symlink(folders[random.below(folders.count)], path)
            case 88..<91:
                symlink(root + "/nowhere/" + name(), path)
            case 91..<94:
                // A loop: two links pointing at each other, and one at itself.
                let other = folder + "/" + name()
                symlink(other, path)
                symlink(path, other)
                symlink(folder + "/" + name(), folder + "/" + name())
            default:
                writeFile(path)
            }
        }
    }

    mutating func build(hugeFolder: Bool) {
        fill(root, depth: 0)
        // A chain 64 folders deep, with a file every few levels.
        var path = root
        for level in 1...64 {
            path += "/c\(level % 10)"
            mkdir(path, 0o755)
            if level % 8 == 0 { writeFile(path + "/" + name()) }
        }
        if let file = files.last { link(file, path + "/far-link") }
        if hugeFolder {
            let huge = root + "/huge"
            mkdir(huge, 0o755)
            for index in 0..<20_000 {
                let entry = huge + "/e\(index)"
                if index % 1_000 == 0 {
                    writeFile(entry)
                } else {
                    FileManager.default.createFile(atPath: entry, contents: nil)
                }
            }
        }
    }
}

private func du(_ path: String) throws -> Int64 {
    let output = try sh(["du", "-skx", path])
    return try #require(Int64(output.split(separator: "\t").first ?? "")) * 1024
}

/// Entries below `path`, counted by NUL separators since names can hold newlines.
private func findCount(_ path: String) throws -> Int64 {
    let output = try sh(["sh", "-c", "find -x \"$0\" -print0 | tr -cd '\\000' | wc -c", path])
    return try #require(Int64(output.trimmingCharacters(in: .whitespaces))) - 1
}

@Suite struct WalkPropertyTests {
    /// The walk's allocated bytes match `du -skx` exactly (du counts 512-byte
    /// blocks and rounds the total up to KB; APFS allocates 4 KB blocks, so
    /// there is nothing to round), and its items match `find -x`, minus the
    /// root, which find prints and the walk doesn't count.
    @Test(arguments: [1, 2, 3, 2026] as [UInt64])
    func matchesDuAndFind(seed: UInt64) throws {
        let dir = try TempDir("tree-\(seed)")
        var tree = RandomTree(seed: seed, root: dir.path)
        tree.build(hugeFolder: seed == 2026)
        let expectedBytes = try du(dir.path)
        let expectedItems = try findCount(dir.path)
        for threads in [1, 8] {
            let result = try Walker(root: dir.path, delegate: SizeOnly(), threadCount: threads).run()
            #expect(result.readErrors == 0, "seed \(seed), \(threads) threads")
            #expect(result.totalBytes == expectedBytes, "seed \(seed), \(threads) threads")
            #expect(result.items == expectedItems, "seed \(seed), \(threads) threads")
        }
        // Seeds 1, 2, 3 and 2026 make 239 to 680 files and 503 to 20,443 items.
        #expect(tree.files.count > 200, "\(tree.files.count) files")
    }
}
