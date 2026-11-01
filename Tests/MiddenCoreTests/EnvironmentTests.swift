import Foundation
import Testing
@testable import MiddenCore

// Python virtual environments under any name, found by their pyvenv.cfg
// and the layout `python -m venv` makes. Always Review: an environment can
// hold packages installed by hand and files changed in place that no
// requirements file records.

@Suite struct EnvironmentTests {
    /// Writes what `python -m venv` makes, with the given pyvenv.cfg.
    private func makeEnvironment(_ home: TempDir, _ relative: String, config: String = "home = /usr/bin\nversion = 3.12.4\n") throws {
        try home.write(relative + "/pyvenv.cfg", text: config)
        try home.write(relative + "/bin/python", bytes: 10)
        try home.write(relative + "/lib/python3.12/site-packages/handmade.py", bytes: 100_000)
    }

    @Test func findsAnEnvironmentUnderAnyName() async throws {
        let home = try TempDir("home")
        try home.write("tools/requirements.txt", text: "requests\n")
        try makeEnvironment(home, "tools/venvs/py312")
        #expect(try reclassify(home, "tools/venvs/py312").buildFolder == .pythonEnvironment)

        let (_, byPath) = try await scanAll(home)
        let environment = try #require(byPath[home.path("tools/venvs/py312")])
        #expect(environment.safety == .review)
        #expect(environment.explanation.contains("by hand"))
        #expect(environment.title == "py312 in venvs")
    }

    @Test func needsAPlausibleEnvironment() throws {
        let home = try TempDir("home")
        // A pyvenv.cfg alone, in a project folder.
        try home.write("notes/pyvenv.cfg", text: "home = /usr/bin\n")
        try home.write("notes/todo.md", bytes: 10)
        // The marker is a symlink to a real one.
        try makeEnvironment(home, "real")
        try home.write("linked/bin/python", bytes: 10)
        try home.mkdir("linked/lib")
        try FileManager.default.createSymbolicLink(
            atPath: home.path("linked/pyvenv.cfg"), withDestinationPath: home.path("real/pyvenv.cfg"))
        // A pyvenv.cfg that doesn't say which Python it was made from.
        try makeEnvironment(home, "partial", config: "include-system-site-packages = false\n")
        // bin is a symlink, not a folder.
        try home.write("aliased/pyvenv.cfg", text: "home = /usr/bin\n")
        try home.mkdir("aliased/lib")
        try FileManager.default.createSymbolicLink(atPath: home.path("aliased/bin"), withDestinationPath: "/usr/bin")

        for folder in ["notes", "linked", "partial", "aliased"] {
            let result = try reclassify(home, folder)
            #expect(result.buildFolder == nil, "\(folder)")
        }
        #expect(try reclassify(home, "real").buildFolder == .pythonEnvironment)
    }

    /// An environment named like a build folder, beside that build tool's
    /// project file, is still an environment: Review, and kept when every
    /// Safe item is cleaned. So is one whose pyvenv.cfg can't be read.
    @Test func environmentsNamedLikeBuildFoldersStayReview() async throws {
        let home = try TempDir("home")
        let cases = [
            ("js", "package.json", "node_modules"), ("rs", "Cargo.toml", "target"), ("gr", "build.gradle", "build"),
            ("sw", "Package.swift", ".build"), ("py", "pyproject.toml", ".mypy_cache"),
        ]
        for (project, marker, name) in cases {
            try home.write("\(project)/\(marker)", text: "x")
            try makeEnvironment(home, "\(project)/\(name)")
            try home.touch("\(project)/\(marker)", daysAgo: 30)
        }
        try home.write("locked/package.json", text: "{}")
        try home.touch("locked/package.json", daysAgo: 30)
        try makeEnvironment(home, "locked/node_modules")
        chmod(home.path("locked/node_modules/pyvenv.cfg"), 0o000)
        defer { chmod(home.path("locked/node_modules/pyvenv.cfg"), 0o644) }
        try home.write("Library/Caches/Yarn/blob", bytes: 10_000)

        let (report, byPath) = try await scanAll(home)
        for folder in cases.map({ "\($0.0)/\($0.2)" }) + ["locked/node_modules"] {
            let finding = try #require(byPath[home.path(folder)], "\(folder)")
            #expect(finding.safety == .review, "\(folder)")
            #expect(finding.explanation.contains("virtual environment"), "\(folder)")
        }
        let safe = report.findings.filter { $0.safety == .safe }.map(\.id)
        #expect(!safe.isEmpty)
        let results = await testCleaner(home).clean(safe).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        for folder in cases.map({ "\($0.0)/\($0.2)" }) + ["locked/node_modules"] {
            #expect(pathExists(home.path(folder + "/lib/python3.12/site-packages/handmade.py")), "\(folder)")
        }
    }

    /// Environments inside tool folders, ~/Library, or another finding are
    /// left to those.
    @Test func leavesEnvironmentsUnderProtectedAncestorsAlone() throws {
        let home = try TempDir("home")
        try makeEnvironment(home, ".local/share/virtualenvs/app-x1y2")
        try makeEnvironment(home, "Library/Application Support/Tool/env")
        try makeEnvironment(home, "Library/Caches/pypoetry/virtualenvs/app-a1b2")
        try makeEnvironment(home, "work/outer")
        try makeEnvironment(home, "work/outer/nested")
        #expect(try reclassify(home, ".local/share/virtualenvs/app-x1y2").buildFolder == nil)
        #expect(try reclassify(home, "Library/Application Support/Tool/env").buildFolder == nil)
        #expect(try reclassify(home, "Library/Caches/pypoetry/virtualenvs/app-a1b2").insideAncestor
            == home.path("Library/Caches/pypoetry/virtualenvs"))
        #expect(try reclassify(home, "work/outer/nested").insideAncestor == home.path("work/outer"))
    }
}
