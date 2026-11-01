import Foundation
import Testing
@testable import MiddenCore

// Data that tools keep inside cache folders but that isn't a cache, carved
// out of the folders around it. Each test scans, plans and cleans a fake
// home in a temporary folder.

@Suite struct CarveOutTests {
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
