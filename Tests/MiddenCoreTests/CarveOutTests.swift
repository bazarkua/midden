import Foundation
import Testing
@testable import MiddenCore

// Data that tools keep inside cache folders but that isn't a cache, carved
// out of the folders around it. Each test scans, plans and cleans a fake
// home in a temporary folder.

/// Scans a fake home with a given process listing, reporting everything.
func scanFindings(_ home: TempDir, processes: ProcessUsage? = nil) async throws -> [String: Finding] {
    var options = ScanOptions.fakeHome(home, minimumBytes: 1)
    if let processes { options.processUsage = { processes } }
    let report = try await Scanner(options: options).scan()
    return Dictionary(report.findings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
}

/// Runs `/bin/sh script` from `directory` until the returned process is
/// terminated. The script's path appears only in the arguments.
func runScript(_ script: String, from directory: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    try process.run()
    return process
}

@Suite struct CarveOutTests {
    // MARK: pnpm dlx

    static let pnpm = "Library/Caches/pnpm"
    static let dlxTool = pnpm + "/dlx/5f2a/node_modules/.bin/tool"

    private func makePnpmHome() throws -> TempDir {
        let home = try TempDir("home")
        try home.write(Self.dlxTool, text: "#!/bin/sh\nwhile :; do sleep 0.2; done\n")
        chmod(home.path(Self.dlxTool), 0o755)
        try home.write(Self.pnpm + "/dlx/5f2a/node_modules/tool/index.js", bytes: 200_000)
        try home.write(Self.pnpm + "/metadata-v1.3/registry.npmjs.org/left-pad.json", bytes: 100_000)
        // Untouched for two months. That says nothing about whether a
        // running program uses it.
        for path in ["/dlx/5f2a/node_modules/tool/index.js", "/dlx/5f2a/node_modules/tool", "/dlx/5f2a/node_modules",
                     "/dlx/5f2a", "/dlx"] {
            try home.touch(Self.pnpm + path, daysAgo: 60)
        }
        return home
    }

    @Test func pnpmDlxIsReviewAndItsParentIsNeverRemoved() async throws {
        let home = try makePnpmHome()
        let byPath = try await scanFindings(home)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        // Old, idle and still only Review: its age isn't evidence of disuse.
        #expect(dlx.safety == .review)
        #expect(dlx.action == .removeDirectory)
        #expect(dlx.checks.map(\.id) == ["inUse"])
        #expect(dlx.checks.first?.passed == true)
        #expect(byPath[home.path(Self.pnpm + "/metadata-v1.3")]?.safety == .safe)

        for result in await testCleaner(home).clean([home.path(Self.pnpm), home.path("Library/Caches")]).results {
            #expect(!result.ok, "\(result.id)")
        }
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    /// A command pnpm dlx installed is running, started from another
    /// folder: its script's path is only in the process's arguments.
    @Test func aRunningDlxCommandKeepsItsFolder() async throws {
        let home = try makePnpmHome()
        let process = try runScript(home.path(Self.dlxTool), from: home.path)
        defer { process.terminate() }

        let byPath = try await scanFindings(home)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        #expect(dlx.safety == .info)
        #expect(!dlx.action.isAutomatic)
        #expect(dlx.checks.first?.passed == false)
        #expect(dlx.checks.first?.detail.contains("pid \(process.processIdentifier)") == true, "\(dlx.checks)")

        let result = try #require(await testCleaner(home).clean([home.path(Self.pnpm + "/dlx")]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("Quit") == true, "\(result)")
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    /// Without a complete process listing, nothing counts as unused.
    @Test func unknownProcessStateKeepsDlx() async throws {
        let home = try makePnpmHome()
        let unknown = ProcessUsage(processes: [], failure: "the system wouldn't list processes (test)")
        let byPath = try await scanFindings(home, processes: unknown)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        #expect(dlx.safety == .info)
        #expect(dlx.checks.first?.detail.contains("Couldn't check") == true, "\(dlx.checks)")

        var cleaner = testCleaner(home)
        cleaner.processUsage = { unknown }
        let result = try #require(await cleaner.clean([home.path(Self.pnpm + "/dlx")]).results.first)
        #expect(!result.ok)
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    @Test func argumentsNameAFolderOnlyAtPathBoundaries() {
        let path = "/Users/me/Library/Caches/pnpm/dlx"
        #expect(ProcessUsage.mentions(path, path))
        #expect(ProcessUsage.mentions(path + "/x/bin.js", path))
        #expect(ProcessUsage.mentions("--user-data-dir=" + path, path))
        #expect(ProcessUsage.mentions("--cache=" + path + "/y", path))
        #expect(!ProcessUsage.mentions(path + "2/x", path))
        #expect(!ProcessUsage.mentions("/private" + path, path))
    }

    // MARK: renv

    /// renv installs each package once into its cache and links it into
    /// every project's library. Cleaning everything Midden offers, Safe
    /// and Review alike, must leave a renv project's packages loadable.
    @Test func renvProjectsKeepTheirPackagesWhenEverythingElseIsCleaned() async throws {
        let home = try TempDir("home")
        let cached = OwnershipTests.renv + "/cache/v5/R-4.4/aarch64-apple-darwin20/jsonlite/1.8.8/0a1b2c3d/jsonlite"
        try home.write(cached + "/DESCRIPTION", text: "Package: jsonlite\nVersion: 1.8.8\n")
        try home.write(cached + "/R/jsonlite.rdb", bytes: 200_000)
        try home.write("Library/Caches/org.R-project.R/R/pak/metadata.rds", bytes: 200_000)
        try home.write("Library/Caches/com.example.other/blob", bytes: 200_000)
        try home.write("Library/Caches/Yarn/v6/blob", bytes: 200_000)
        let library = try home.mkdir("code/analysis/renv/library/R-4.4/aarch64-apple-darwin20")
        try home.write("code/analysis/renv.lock", text: "{}")
        try FileManager.default.createSymbolicLink(atPath: library + "/jsonlite", withDestinationPath: home.path(cached))

        let (report, byPath) = try await scanAll(home)
        #expect(byPath[home.path(OwnershipTests.renv)]?.safety == .info)
        let offered = report.findings.filter { $0.action.isAutomatic && $0.category != .largeFiles }.map(\.id)
        #expect(offered.contains(home.path("Library/Caches/Yarn")))
        #expect(offered.contains(home.path("Library/Caches/com.example.other")))
        let results = await testCleaner(home).clean(offered).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")

        // The project's link still leads to the package.
        let description = try String(contentsOfFile: library + "/jsonlite/DESCRIPTION", encoding: .utf8)
        #expect(description.contains("Package: jsonlite"))
        #expect(!pathExists(home.path("Library/Caches/Yarn")))
    }

    // MARK: Poetry

    static let poetry = "Library/Caches/pypoetry"
    static let environment = poetry + "/virtualenvs/app-Xa1b2c3-py3.12"
    static let handmade = environment + "/lib/python3.12/site-packages/handmade/__init__.py"

    /// Poetry keeps every project's virtual environment in its cache
    /// folder. One can hold a package installed by hand or a file edited
    /// in place, which no lock file records, so environments are Review
    /// and never go with their parent.
    @Test func poetryEnvironmentsAreReviewAndSurviveTheirParent() async throws {
        let home = try TempDir("home")
        try home.write(Self.environment + "/pyvenv.cfg", text: "home = /usr/bin\nversion = 3.12.4\n")
        try home.write(Self.handmade, bytes: 50_000)
        try home.write(Self.poetry + "/cache/repositories/PyPI/_http/a/b/c", bytes: 200_000)
        try home.write(Self.poetry + "/artifacts/ab/cd/requests-2.32.3-py3-none-any.whl", bytes: 300_000)
        try home.write(Self.poetry + "/unknown/data", bytes: 10_000)
        let (_, byPath) = try await scanAll(home)

        let environments = try #require(byPath[home.path(Self.poetry + "/virtualenvs")])
        #expect(environments.safety == .review)
        #expect(environments.explanation.contains("by hand"))
        for safe in ["cache", "artifacts"] {
            let finding = try #require(byPath[home.path(Self.poetry + "/" + safe)], "\(safe)")
            #expect(finding.safety == .safe, "\(safe)")
        }
        let parent = try #require(byPath[home.path(Self.poetry)])
        #expect(parent.safety == .info)
        #expect(!parent.action.isAutomatic)
        // The environment isn't also a build folder of its own.
        #expect(byPath[home.path(Self.environment)] == nil)

        // The wildcard above can't take the environments with it.
        let above = [Self.poetry, "Library/Caches", Self.environment]
        for result in await testCleaner(home).clean(above.map(home.path)).results {
            #expect(!result.ok, "\(result.id)")
        }
        // Cleaning the Safe parts beside them leaves them alone.
        let safe = await testCleaner(home).clean([home.path(Self.poetry + "/cache"), home.path(Self.poetry + "/artifacts")])
        #expect(safe.results.allSatisfy { $0.ok }, "\(safe.results)")
        #expect(pathExists(home.path(Self.handmade)))
        #expect(!pathExists(home.path(Self.poetry + "/cache")))
    }
}
