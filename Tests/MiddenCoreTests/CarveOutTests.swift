import Foundation
import Testing
@testable import MiddenCore

// Data that tools keep inside cache folders but that isn't a cache, carved
// out of the folders around it. Each test scans, plans and cleans a fake
// home in a temporary folder.

@Suite struct CarveOutTests {
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
