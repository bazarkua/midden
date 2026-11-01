import Foundation
import Testing
@testable import MiddenCore

// A SwiftPM package's .build folder holds build products, which the next
// build makes again, next to things `swift package clean` deliberately
// keeps: dependency checkouts (possibly edited by hand), cached
// repositories, binary artifacts and workspace-state.json. Midden cleans
// it the same way and keeps the same things.

@Suite struct SwiftPMTests {
    static let project = "code/tool"
    static let build = project + "/.build"
    static let kept = ["artifacts", "checkouts", "repositories", "workspace-state.json"]

    private func makePackage(_ home: TempDir, idleDays: Double = 30) throws {
        try home.write(Self.project + "/Package.swift", text: "// swift-tools-version: 6.0\n")
        try home.write(Self.project + "/Sources/Tool/main.swift", text: "print(1)\n")
        try home.write(Self.build + "/workspace-state.json", text: "{}")
        try home.write(Self.build + "/repositories/swift-argument-parser-1a2b/HEAD", text: "ref: x\n")
        try home.write(Self.build + "/checkouts/swift-argument-parser/Sources/ArgumentParser/Edited.swift", bytes: 30_000)
        try home.write(Self.build + "/artifacts/tool/Lib.xcframework/Info.plist", bytes: 30_000)
        try home.write(Self.build + "/arm64-apple-macosx/debug/tool", text: "#!/bin/sh\nwhile :; do sleep 0.2; done\n")
        chmod(home.path(Self.build + "/arm64-apple-macosx/debug/tool"), 0o755)
        try home.write(Self.build + "/arm64-apple-macosx/debug/Tool.build/main.swift.o", bytes: 400_000)
        try home.write(Self.build + "/plugins/cache/x", bytes: 100_000)
        try home.write(Self.build + "/description.json", bytes: 20_000)
        try FileManager.default.createSymbolicLink(
            atPath: home.path(Self.build + "/debug"), withDestinationPath: "arm64-apple-macosx/debug")
        for path in ["/Package.swift", "/Sources/Tool/main.swift", "/Sources/Tool", "/Sources"] {
            try home.touch(Self.project + path, daysAgo: idleDays)
        }
    }

    @Test func cleansBuildProductsAndKeepsWhatSwiftPMKeeps() async throws {
        let home = try TempDir("home")
        try makePackage(home)
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path(Self.build))
        let products = before.filter { !Self.kept.contains($0) }
        var expected: Int64 = 0
        for name in products {
            let path = home.path(Self.build + "/" + name)
            var info = stat()
            lstat(path, &info)
            expected += info.st_mode & S_IFMT == S_IFDIR ? try allocated(path) : Int64(info.st_blocks) * 512
        }

        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        let finding = try #require(byPath[home.path(Self.build)])
        #expect(finding.category == .buildFolders)
        #expect(finding.safety == .safe)
        #expect(finding.action == .removeContents)
        #expect(finding.bytes == expected)
        #expect(finding.explanation.contains("swift package clean"))
        #expect(finding.checks.map(\.id) == ["projectIdle", "measured", "inUse"])

        let result = try #require(await testCleaner(home).clean([home.path(Self.build)]).results.first)
        #expect(result.ok, "\(result)")
        #expect(result.freedBytes > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path(Self.build)).sorted() == Self.kept)
        #expect(pathExists(home.path(Self.build + "/checkouts/swift-argument-parser/Sources/ArgumentParser/Edited.swift")))
        #expect(pathExists(home.path(Self.build + "/repositories/swift-argument-parser-1a2b/HEAD")))
        #expect(pathExists(home.path(Self.project + "/Package.swift")))
    }

    @Test func needsThePackageManifestAndAReadableFolder() async throws {
        let home = try TempDir("home")
        try home.write("code/other/.build/arm64-apple-macosx/debug/x.o", bytes: 100_000)
        try makePackage(home)
        chmod(home.path(Self.build), 0o000)
        defer { chmod(home.path(Self.build), 0o755) }
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        #expect(byPath[home.path("code/other/.build")] == nil)
        #expect(byPath[home.path(Self.build)] == nil)
    }

    /// A build running, or the package changed lately, holds it back.
    @Test func anActiveBuildKeepsItsProducts() async throws {
        let home = try TempDir("home")
        try makePackage(home)
        let process = try runScript(home.path(Self.build + "/arm64-apple-macosx/debug/tool"), from: home.path)
        defer { process.terminate() }
        let result = try #require(await testCleaner(home).clean([home.path(Self.build)]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("Quit") == true, "\(result)")
        #expect(pathExists(home.path(Self.build + "/arm64-apple-macosx/debug/Tool.build/main.swift.o")))

        let fresh = try TempDir("home")
        try makePackage(fresh, idleDays: 1)
        let byPath = try await scanFindings(fresh, processes: ProcessUsage(processes: []))
        #expect(byPath[fresh.path(Self.build)]?.safety == .review)
    }
}
