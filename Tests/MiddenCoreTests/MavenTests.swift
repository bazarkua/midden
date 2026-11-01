import Foundation
import Testing
@testable import MiddenCore

// Maven's repository stays Review: `mvn install` puts libraries there that
// exist nowhere else.

@Suite struct MavenTests {
    /// A library installed with `mvn install` exists only in ~/.m2. The
    /// repository stays Review and says so, and cleaning everything Safe
    /// leaves it alone.
    @Test func aLocallyInstalledMavenArtifactSurvivesCleaningSafeItems() async throws {
        let home = try TempDir("home")
        let local = ".m2/repository/com/example/local-lib/1.0-SNAPSHOT"
        let jar = try home.write(local + "/local-lib-1.0-SNAPSHOT.jar", bytes: 200_000)
        try home.write(local + "/maven-metadata-local.xml", text: "<metadata/>")
        try home.write(".m2/repository/org/example/remote/2.0/remote-2.0.jar", bytes: 200_000)
        try home.write(".m2/repository/org/example/remote/2.0/_remote.repositories", text: "remote-2.0.jar>central=\n")
        try home.write("Library/Caches/Yarn/v6/blob", bytes: 100_000)
        let (report, byPath) = try await scanAll(home)

        let repository = try #require(byPath[home.path(".m2/repository")])
        #expect(repository.safety == .review)
        #expect(repository.explanation.contains("mvn install"))
        let safe = report.findings.filter { $0.safety == .safe }.map(\.id)
        #expect(!safe.isEmpty)
        let results = await testCleaner(home).clean(safe).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        #expect(pathExists(jar))
    }
}
