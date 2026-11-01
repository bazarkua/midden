import Foundation
import Testing
@testable import MiddenCore

@Suite struct ScannerTests {
    /// A fake home with one of everything.
    private func makeHome() throws -> (TempDir, worktree: String) {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/data/blob1", bytes: 3_000_000)
        try home.write("Library/Caches/com.example.fake/data/blob2", bytes: 1_500_000)
        try home.write("Library/Caches/com.example.fake/index", bytes: 1_200_000)
        try home.write("Library/Caches/com.example.tiny/x", bytes: 10_000)
        try home.write("Library/Caches/com.apple.Something/x", bytes: 3_000_000)
        try home.write("Library/Developer/Xcode/DerivedData/App-abc/Build/out", bytes: 2_000_000)
        try home.write("Library/Logs/app.log", bytes: 1_100_000)
        try home.write("Downloads/Installer.dmg", bytes: 101_000_000)
        try home.write("Downloads/notes.txt", text: "hi")
        try home.write("Projects/old/package.json", text: "{}")
        try home.write("Projects/old/node_modules/dep/index.js", bytes: 2_000_000)
        try home.touch("Projects/old/package.json", daysAgo: 30)
        try home.write("Projects/fresh/package.json", text: "{}")
        try home.write("Projects/fresh/node_modules/dep/index.js", bytes: 2_000_000)
        try home.write(".vscode/extensions/ext/package.json", text: "{}")
        try home.write(".vscode/extensions/ext/node_modules/dep/index.js", bytes: 2_000_000)
        let repository = try makeRepository(home, "Projects/repo")
        let worktree = try addWorktree(home, repository: repository, branch: "agent-task")
        try home.write("worktrees/agent-task/node_modules/dep/index.js", bytes: 2_000_000)
        return (home, worktree)
    }

    private func scan(_ home: TempDir) async throws -> ScanReport {
        var options = ScanOptions(home: home.url, minimumBytes: 1_000_000)
        options.threadCount = 4
        options.worktreeActiveWindow = 0
        return try await Scanner(options: options).scan()
    }

    @Test func findsEverythingInAFakeHome() async throws {
        let (home, worktree) = try makeHome()
        let report = try await scan(home)
        let byPath = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.path, $0) })

        let cache = try #require(byPath[home.path("Library/Caches/com.example.fake")])
        #expect(cache.category == .appCaches)
        #expect(cache.safety == .safe)
        #expect(cache.action == .removeDirectory)
        #expect(cache.app?.bundleID == "com.example.fake")
        #expect(cache.breakdown.map(\.name) == ["data", "index"])
        #expect(cache.breakdown.reduce(0) { $0 + $1.bytes } == cache.bytes)

        #expect(byPath[home.path("Library/Developer/Xcode/DerivedData")]?.safety == .safe)
        #expect(byPath[home.path("Library/Logs")]?.action == .removeContents)
        #expect(byPath[home.path("Library/Caches/com.apple.Something")] == nil)
        #expect(byPath[home.path("Library/Caches/com.example.tiny")] == nil)

        let installer = try #require(byPath[home.path("Downloads/Installer.dmg")])
        #expect(installer.category == .largeFiles)
        #expect(installer.action == .removeFile)
        #expect(byPath[home.path("Downloads")]?.safety == .info)

        let old = try #require(byPath[home.path("Projects/old/node_modules")])
        #expect(old.safety == .safe)
        #expect(old.group == "old")
        #expect(old.checks.first?.passed == true)
        let fresh = try #require(byPath[home.path("Projects/fresh/node_modules")])
        #expect(fresh.safety == .review)
        #expect(fresh.checks.first?.passed == false)
        #expect(byPath[home.path(".vscode/extensions/ext/node_modules")] == nil)

        let tree = try #require(byPath[worktree])
        #expect(tree.category == .worktrees)
        #expect(tree.safety == .safe)
        #expect(tree.group == "repo")
        #expect(tree.breakdown.first?.name == "node_modules")
        // Its node_modules is part of the worktree, not a separate finding.
        #expect(byPath[worktree + "/node_modules"] == nil)

        #expect(report.findings.map(\.bytes) == report.findings.map(\.bytes).sorted(by: >))
        let known: Set<String> = [
            "uncommitted", "onBranch", "locked", "inUse", "lastActivity", "gitInstalled",
            "gitReadable", "repositoryExists", "projectIdle", "packagesRecorded", "simulatorUnavailable",
        ]
        #expect(report.findings.flatMap(\.checks).allSatisfy { known.contains($0.id) })
        #expect(tree.checks.map(\.id) == ["uncommitted", "onBranch", "locked", "inUse", "lastActivity"])
        #expect(report.disk.volumeName?.isEmpty == false)
        #expect(report.home == home.path)
        #expect(report.needsFullDiskAccess == false)
        #expect(report.unreadableCount == 0)
        #expect(report.disk.total > 0 && report.disk.free > 0)
        #expect(report.topFolders.first?.name == "Downloads")
        #expect(Set(report.topFolders.map(\.name)).isSuperset(of: ["Library", "Projects", ".vscode"]))
    }

    @Test func bytesScannedMatchesDu() async throws {
        let (home, _) = try makeHome()
        let report = try await scan(home)
        let du = try sh(["du", "-sk", home.path])
        let kilobytes = try #require(Int64(du.split(separator: "\t").first ?? ""))
        #expect(report.bytesScanned == kilobytes * 1024)
        #expect(report.topFolders.reduce(0) { $0 + $1.bytes } <= report.bytesScanned)
    }

    @Test func reportRoundTripsThroughJSON() async throws {
        let (home, _) = try makeHome()
        let report = try await scan(home)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanReport.self, from: encoder.encode(report))
        #expect(decoded.findings == report.findings.map { finding in
            var finding = finding
            // ISO 8601 keeps whole seconds.
            finding.lastActivity = finding.lastActivity.map {
                Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down))
            }
            return finding
        })
    }

    @Test func unreadableHomeIsAnErrorNotAnEmptyReport() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 2_000_000)
        chmod(home.path, 0o000)
        defer { chmod(home.path, 0o755) }
        await #expect(throws: MiddenError.self) {
            try await Scanner(options: ScanOptions(home: home.url)).scan()
        }
        do {
            _ = try await Scanner(options: ScanOptions(home: home.url)).scan()
        } catch MiddenError.unreadable(let path, let code) {
            #expect(path == home.path)
            #expect(code == EACCES)
        }
        let missing = home.url.appendingPathComponent("does-not-exist")
        await #expect(throws: MiddenError.self) {
            try await Scanner(options: ScanOptions(home: missing)).scan()
        }
    }

    @Test func cancellingTheTaskThrowsCancelled() async throws {
        let (home, _) = try makeHome()
        let scanner = Scanner(options: ScanOptions(home: home.url))
        let task = Task {
            // Starts scanning only once cancelled, so the outcome is deterministic.
            while !Task.isCancelled { await Task.yield() }
            return try await scanner.scan()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled scan returned a report")
        } catch {
            #expect(error as? MiddenError == .cancelled)
        }
    }

    @Test func probesFullDiskAccess() async throws {
        let home = try TempDir("home")
        // No protected folders exist in a fake home, so nothing is refused.
        #expect(FullDiskAccess.isGranted(home: home.url))
        #expect(await FullDiskAccess.check(home: home.url))
        try home.mkdir("Library/Safari")
        chmod(home.path("Library/Safari"), 0o000)
        defer { chmod(home.path("Library/Safari"), 0o755) }
        #expect(!FullDiskAccess.isGranted(home: home.url))
        #expect(!(await FullDiskAccess.check(home: home.url)))
    }

    @Test func parsesSimctlOutput() throws {
        let json = """
            {"devices": {
              "com.apple.CoreSimulator.SimRuntime.iOS-17-2": [
                {"udid": "AAA", "name": "iPhone 15", "isAvailable": false,
                 "availabilityError": "runtime profile not found", "state": "Shutdown"}],
              "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"udid": "BBB", "name": "iPhone 17", "isAvailable": true, "state": "Shutdown"}]
            }}
            """
        let devices = try #require(Simulators.parse(Data(json.utf8)))
        #expect(devices.count == 2)
        let gone = try #require(devices.first { !$0.isAvailable })
        #expect(gone.runtimeName == "iOS 17.2")
        let finding = Findings.simulator(gone, path: "/x/AAA", bytes: 5)
        #expect(finding.id == "sim:AAA")
        #expect(finding.action == CleanAction.run(["xcrun", "simctl", "delete", "AAA"]))
    }

    @Test func reportsAHardLinkedFileOnce() async throws {
        let home = try TempDir("home")
        let original = try home.write("Downloads/releases/1.0/tool.dmg", bytes: 100_000_000)
        let link = home.path("Downloads/releases/latest/tool.dmg")
        try home.mkdir("Downloads/releases/latest")
        try FileManager.default.linkItem(atPath: original, toPath: link)

        let report = try await Scanner(options: ScanOptions(home: home.url, minimumBytes: 1_000_000)).scan()
        let files = report.findings.filter { $0.category == .largeFiles }
        #expect(files.count == 1)
        #expect(files.first?.path == original)
        #expect(files.first?.explanation.contains("Also at \(link).") == true)
        let downloads = try #require(report.findings.first { $0.path == home.path("Downloads") })
        #expect(downloads.bytes < 2 * 100_000_000)
    }
}
