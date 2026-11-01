import Foundation
import Testing
@testable import MiddenCore

// A rule's folder can hold folders other rules match, such as renv's
// package cache inside R's cache folder. Such a folder is a container: the
// scanner keeps classifying inside it, its own finding is only what's left
// over, and the cleaner never removes it as a whole. Every test here scans,
// plans and cleans a fake home in a temporary folder.

func pathExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// Bytes allocated under `path`, measured the way the scanner measures.
func allocated(_ path: String) throws -> Int64 {
    try Walker(root: path, delegate: SizeOnly()).run().totalBytes
}

/// A cleaner whose Trash is a folder inside the fake home.
func testCleaner(_ home: TempDir) -> Cleaner {
    var cleaner = Cleaner(home: home.url)
    let bin = home.path(".test-trash")
    cleaner.trash = { path in
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: bin + "/" + (path as NSString).lastPathComponent)
    }
    return cleaner
}

/// Scans a fake home, reporting everything regardless of size.
func scanAll(_ home: TempDir) async throws -> (ScanReport, [String: Finding]) {
    var options = ScanOptions.fakeHome(home, minimumBytes: 1)
    options.threadCount = 4
    let report = try await Scanner(options: options).scan()
    return (report, Dictionary(report.findings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }))
}

@Suite struct OwnershipTests {
    static let rCache = "Library/Caches/org.R-project.R"
    static let renv = rCache + "/R/renv"
    static let package = renv + "/cache/v5/R-4.4/aarch64-apple-darwin20/jsonlite/1.8.8/0a1b2c3d/jsonlite/DESCRIPTION"

    private func makeRHome() throws -> TempDir {
        let home = try TempDir("home")
        try home.write(Self.package, bytes: 300_000)
        try home.write(Self.rCache + "/R/pak/metadata.rds", bytes: 200_000)
        try home.write(Self.rCache + "/loose.txt", bytes: 100_000)
        return home
    }

    @Test func protectedDescendantSurvivesCleaningEverythingAboveIt() async throws {
        let home = try makeRHome()
        let (report, byPath) = try await scanAll(home)

        // The scanner reached the descendant through the cache wildcard.
        let renv = try #require(byPath[home.path(Self.renv)])
        #expect(renv.safety == .info)
        #expect(!renv.action.isAutomatic)
        // Its parent is still reported, but only for what's left, and
        // Midden never removes it as a whole.
        let parent = try #require(byPath[home.path(Self.rCache)])
        #expect(!parent.action.isAutomatic)
        #expect(parent.safety == .info)
        #expect(parent.explanation.contains("renv"))
        #expect(parent.bytes + renv.bytes == (try allocated(home.path(Self.rCache))))
        #expect(parent.breakdown.reduce(0) { $0 + $1.bytes } == parent.bytes)
        #expect(report.reclaimable(.safe) == 0)

        let above = [Self.renv, Self.rCache + "/R", Self.rCache, "Library/Caches", "Library"]
        let plans = await testCleaner(home).plan(above.map(home.path))
        for plan in plans {
            #expect(!plan.isApproved, "\(plan.id)")
        }
        let results = await testCleaner(home).clean(above.map(home.path)).results
        for result in results {
            #expect(!result.ok, "\(result.id)")
        }
        #expect(pathExists(home.path(Self.package)))
        #expect(pathExists(home.path(Self.rCache + "/R/pak/metadata.rds")))
    }

    @Test func containerRefusalSaysWhy() async throws {
        let home = try makeRHome()
        let plan = try #require(await testCleaner(home).plan([home.path(Self.rCache)]).first)
        #expect(plan.refusal?.contains("doesn't delete this itself") == true, "\(plan)")
        // The plan shows the same remainder the scan showed.
        let remainder = try allocated(home.path(Self.rCache)) - (try allocated(home.path(Self.renv)))
        #expect(plan.finding?.bytes == remainder)
        // Something inside the container that no rule names belongs to it.
        let inside = try #require(await testCleaner(home).plan([home.path(Self.rCache + "/R/pak")]).first)
        #expect(inside.refusal?.contains("inside") == true, "\(inside)")
        #expect(inside.refusal?.contains(home.path(Self.rCache)) == true, "\(inside)")
    }

    /// Inside a container only rules apply: a project folder in there is
    /// part of the cache, not a project with build folders or big files.
    @Test func onlyRulesApplyInsideAContainer() async throws {
        let home = try makeRHome()
        try home.write(Self.rCache + "/R/tool/package.json", text: "{}")
        try home.write(Self.rCache + "/R/tool/node_modules/dep/index.js", bytes: 10_000)
        try home.write(Self.rCache + "/R/tool/Setup.dmg", bytes: 100_000_000)
        let (_, byPath) = try await scanAll(home)
        #expect(byPath[home.path(Self.rCache + "/R/tool/node_modules")] == nil)
        #expect(byPath[home.path(Self.rCache + "/R/tool/Setup.dmg")] == nil)
        #expect(byPath[home.path(Self.renv)] != nil)
    }

    /// Downloads is reported but doesn't claim what's in it, so an
    /// installer and a project's node_modules inside it are findings of
    /// their own. Downloads' size leaves them out: the three add up to the
    /// folder, nothing counted twice.
    @Test func findingsInsideDownloadsPartitionIt() async throws {
        let home = try TempDir("home")
        try home.write("Downloads/Setup.pkg", bytes: 100_000_000)
        try home.write("Downloads/notes.txt", bytes: 300_000)
        try home.write("Downloads/archive/photos.zip", bytes: 2_000_000)
        try home.write("Downloads/project/package.json", text: "{}")
        try home.write("Downloads/project/node_modules/dep/index.js", bytes: 500_000)
        let (_, byPath) = try await scanAll(home)

        let downloads = try #require(byPath[home.path("Downloads")])
        let installer = try #require(byPath[home.path("Downloads/Setup.pkg")])
        let modules = try #require(byPath[home.path("Downloads/project/node_modules")])
        #expect(downloads.bytes + installer.bytes + modules.bytes == (try allocated(home.path("Downloads"))))
        #expect(downloads.breakdown.reduce(0) { $0 + $1.bytes } == downloads.bytes)
        #expect(!downloads.breakdown.contains { $0.name == "Setup.pkg" })
    }

    /// A folder with rules below it must never be removable as a whole: a
    /// literal rule there says so itself (Info, manual), and a wildcard
    /// that happens to match one is turned into a container when matched.
    @Test func foldersWithRulesBelowThemAreNeverRemovable() {
        for rule in RuleCatalog.rules {
            for path in rule.paths where !path.contains("*") {
                let components = path.split(separator: "/").map(String.init)
                if RuleCatalog.hasNestedRules(below: components) {
                    #expect(!rule.action.isAutomatic, "\(path)")
                    #expect(rule.safety == .info, "\(path)")
                }
            }
        }
        let match = RuleCatalog.match(["Library", "Caches", "org.R-project.R"])
        #expect(match?.rule.action.isAutomatic == false)
    }
}
