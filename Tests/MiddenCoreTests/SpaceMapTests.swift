import Foundation
import Testing
@testable import MiddenCore

/// Every node with children: the children add up to its size exactly.
private func addsUp(_ node: SpaceNode) -> Bool {
    if !node.children.isEmpty, node.children.reduce(0, { $0 + $1.bytes }) != node.bytes { return false }
    return node.children.allSatisfy(addsUp)
}

private func depth(_ node: SpaceNode) -> Int {
    1 + (node.children.map(depth).max() ?? 0)
}

private func all(_ node: SpaceNode) -> [SpaceNode] {
    [node] + node.children.flatMap(all)
}

private func folder(_ path: String, _ bytes: Int64, entries: Int = 1) -> SpaceRecord {
    SpaceRecord(path: path, bytes: bytes, isDirectory: true, entries: entries)
}

private func file(_ path: String, _ bytes: Int64) -> SpaceRecord {
    SpaceRecord(path: path, bytes: bytes, isDirectory: false, entries: 0)
}

@Suite struct SpaceMapTests {
    @Test func mergesSmallChildrenIntoOther() throws {
        let records = [
            folder("/h", 1_000, entries: 5),
            folder("/h/a", 600, entries: 3), file("/h/a/x", 500), folder("/h/a/y", 50),
            folder("/h/b", 300, entries: 2),
            file("/h/tiny", 5),
        ]
        let map = try #require(SpaceMap.build(records, root: "/h", findings: [], floor: 10))
        #expect(map.bytes == 1_000)
        #expect(map.children.map(\.name) == ["a", "b", "Other (3 items)"])
        #expect(map.children.last?.bytes == 100)
        #expect(map.children.last?.isDirectory == false)
        #expect(map.children.last?.isOther == true)
        #expect(map.children.last?.path == "/h/(other)")
        #expect(map.children.dropLast().allSatisfy { !$0.isOther })
        let paths = all(map).map(\.path)
        #expect(Set(paths).count == paths.count)
        let a = map.children[0]
        #expect(a.children.map(\.name) == ["x", "y", "Other (1 item)"])
        // b has no remembered children, so it's a leaf.
        #expect(map.children[1].children.isEmpty)
        #expect(addsUp(map))
    }

    @Test func limitsChildrenAndDepth() throws {
        var records = [folder("/h", 10_000, entries: 60)]
        for index in 0..<50 { records.append(file("/h/f\(index)", 100)) }
        // A chain 12 folders deep under /h/deep.
        var path = "/h/deep"
        for _ in 0..<12 {
            records.append(folder(path, 5_000))
            path += "/d"
        }
        let map = try #require(SpaceMap.build(records, root: "/h", findings: [], floor: 1))
        #expect(map.children.count == SpaceMap.maxChildren + 1)  // 40 kept + Other
        #expect(map.children.first?.name == "deep")
        #expect(map.children.last?.name == "Other (20 items)")
        #expect(depth(map) == SpaceMap.maxDepth + 1)
        #expect(addsUp(map))
    }

    @Test func belowFivePercentOfAThousandthIsOther() throws {
        // 0.05% of 10 GB is 5 MB: the 4 MB folder is merged even though the
        // floor is lower.
        let records = [
            folder("/h", 10_000_000_000, entries: 2),
            folder("/h/big", 9_996_000_000), folder("/h/small", 4_000_000),
        ]
        let map = try #require(SpaceMap.build(records, root: "/h", findings: [], floor: 1_000_000))
        #expect(map.children.map(\.name) == ["big", "Other (1 item)"])
    }

    @Test func onlyAFindingsOwnNodeCarriesItsID() throws {
        let records = [
            folder("/h", 1_000, entries: 2),
            folder("/h/cache", 800, entries: 2), folder("/h/cache/deep", 500), file("/h/cache/big.bin", 200),
            folder("/h/work", 200),
        ]
        let finding = Finding(
            id: "/h/cache", category: .appCaches, title: "c", path: "/h/cache", group: "c", bytes: 800,
            safety: .safe, explanation: "e", action: .removeDirectory)
        let map = try #require(SpaceMap.build(records, root: "/h", findings: [finding], floor: 1))
        let byPath = Dictionary(uniqueKeysWithValues: all(map).map { ($0.path, $0) })
        #expect(byPath["/h/cache"]?.findingID == "/h/cache")
        #expect(byPath["/h/cache/deep"]?.findingID == nil)
        #expect(byPath["/h/work"]?.findingID == nil)
        #expect(map.findingID == nil)
    }

    @Test func findingsAreNeverMergedIntoOther() throws {
        // 41 folders above the threshold, plus two small findings: one below
        // the threshold, one nested deeper than the depth limit.
        var records = [folder("/h", 100_000, entries: 45)]
        for index in 0..<41 { records.append(folder("/h/big\(index)", 2_000)) }
        records.append(folder("/h/small-cache", 30))
        var path = "/h/deep"
        for _ in 0..<12 {
            records.append(folder(path, 1_000))
            path += "/d"
        }
        records.append(folder(path, 1_000))
        let deepFinding = path + "/node_modules"
        records.append(folder(deepFinding, 1_000))
        func finding(_ path: String) -> Finding {
            Finding(
                id: path, category: .buildFolders, title: "t", path: path, group: "g", bytes: 1,
                safety: .safe, explanation: "e", action: .removeDirectory)
        }
        let map = try #require(SpaceMap.build(
            records, root: "/h", findings: [finding("/h/small-cache"), finding(deepFinding)], floor: 1))
        let nodes = all(map)
        let small = try #require(nodes.first { $0.path == "/h/small-cache" })
        #expect(small.findingID == "/h/small-cache")
        #expect(!small.isOther)
        #expect(nodes.contains { $0.path == deepFinding && $0.findingID == deepFinding })
        // The findings and their folders, plus 40 regular children at most.
        #expect(map.children.filter { !$0.isOther }.count == 2 + 38)
        #expect(nodes.filter(\.isOther).allSatisfy { $0.findingID == nil })
        #expect(addsUp(map))
    }

    @Test func aHardLinkedFindingIsMarkedWhereItsBytesAre() async throws {
        let home = try TempDir("home")
        let original = try home.write("Downloads/a/tool.dmg", bytes: 120_000_000)
        try home.mkdir("Downloads/b")
        try FileManager.default.linkItem(atPath: original, toPath: home.path("Downloads/b/tool.dmg"))
        let report = try await Scanner(options: ScanOptions(home: home.url, minimumBytes: 1_000_000)).scan()
        let installer = try #require(report.findings.first { $0.category == .largeFiles })
        let marked = all(try #require(report.spaceMap)).filter { $0.findingID == installer.id }
        // Exactly one node carries it: whichever name the walk counted the bytes under.
        #expect(marked.count == 1)
        #expect(marked.first?.bytes ?? 0 >= 120_000_000)
    }

    @Test func scanBuildsTheTreeWithHardLinksOnce() async throws {
        let home = try TempDir("home")
        try home.write("Projects/app/package.json", text: "{}")
        try home.write("Projects/app/node_modules/dep/big.js", bytes: 30_000_000)
        try home.touch("Projects/app/package.json", daysAgo: 30)
        let original = try home.write("Data/releases/1.0/model.bin", bytes: 25_000_000)
        try home.mkdir("Data/releases/latest")
        try FileManager.default.linkItem(atPath: original, toPath: home.path("Data/releases/latest/model.bin"))
        try home.write("Data/small.txt", bytes: 1_000)

        let report = try await Scanner(options: ScanOptions(home: home.url, minimumBytes: 1_000_000)).scan()
        let map = try #require(report.spaceMap)
        #expect(map.path == home.path)
        #expect(map.bytes == report.bytesScanned)
        #expect(addsUp(map))
        let nodes = all(map)
        // The hard-linked file counts once: only one of its names is big enough to show.
        #expect(nodes.filter { $0.name == "model.bin" }.count == 1)
        let releases = try #require(nodes.first { $0.path == home.path("Data/releases") })
        #expect(releases.bytes < 2 * 25_000_000)
        let modules = try #require(nodes.first { $0.path == home.path("Projects/app/node_modules") })
        #expect(modules.findingID == home.path("Projects/app/node_modules"))
        #expect(nodes.filter { $0.path.hasPrefix(modules.path + "/") }.allSatisfy { $0.findingID == nil })
    }
}
