import Foundation
import Testing
@testable import MiddenCore

/// Classifies `relative` inside a fake home the way the scanner would.
func reclassify(_ home: TempDir, _ relative: String) throws -> Reclassification {
    try Classifier.reclassify(
        relative.split(separator: "/").map(String.init), home: home.path, reader: DirectoryReader())
}

extension Reclassification {
    var buildFolder: BuildFolderKind? {
        if case .directory(.buildFolder(let match)?, _) = self { return match.kind }
        return nil
    }

    var rule: RuleMatch? {
        if case .directory(.rule(let match)?, _) = self { return match }
        return nil
    }

    var isNothing: Bool {
        if case .directory(nil, _) = self { return true }
        return false
    }

    var insideAncestor: String? {
        if case .inside(let ancestor, _) = self { return ancestor }
        return nil
    }
}

@Suite struct ClassifierTests {
    struct BuildCase: Sendable, CustomTestStringConvertible {
        /// Files to create, relative to the fake home.
        var files: [String]
        /// The folder to classify.
        var folder: String
        var expected: BuildFolderKind?
        var testDescription: String { "\(folder) with \(files)" }
    }

    static let buildCases: [BuildCase] = [
        BuildCase(files: ["app/package.json", "app/node_modules/x/i.js"],
                  folder: "app/node_modules", expected: .nodeModules),
        BuildCase(files: ["app/node_modules/x/i.js"], folder: "app/node_modules", expected: nil),
        BuildCase(files: ["web/package.json", "web/.next/cache/a"],
                  folder: "web/.next", expected: .javaScriptBuild(tool: "Next.js")),
        BuildCase(files: ["rs/Cargo.toml", "rs/target/debug/a"], folder: "rs/target", expected: .cargoTarget),
        BuildCase(files: ["java/target/classes/A.class"], folder: "java/target", expected: nil),
        BuildCase(files: ["py/.venv/pyvenv.cfg", "py/.venv/bin/python"],
                  folder: "py/.venv", expected: .pythonEnvironment),
        BuildCase(files: ["py/venv/notes.txt"], folder: "py/venv", expected: nil),
        BuildCase(files: ["ios/Podfile", "ios/Pods/A/a.m"], folder: "ios/Pods", expected: .pods),
        BuildCase(files: ["and/build.gradle.kts", "and/build/out"], folder: "and/build", expected: .gradleBuild),
        BuildCase(files: ["and/settings.gradle", "and/.gradle/x"], folder: "and/.gradle", expected: .gradleCache),
        BuildCase(files: ["fl/pubspec.yaml", "fl/build/out"], folder: "fl/build", expected: .flutterBuild),
        BuildCase(files: ["fl/pubspec.yaml", "fl/.dart_tool/x"], folder: "fl/.dart_tool", expected: .dartTool),
        BuildCase(files: ["docs/build/index.html"], folder: "docs/build", expected: nil),
        BuildCase(files: ["py/.mypy_cache/x"], folder: "py/.mypy_cache", expected: .pythonToolCache(tool: "mypy")),
        // A stray npm install in the home folder itself is still a project.
        BuildCase(files: ["package.json", "node_modules/x/i.js"], folder: "node_modules", expected: .nodeModules),
        // Tools installed in hidden folders and in ~/Library aren't build output.
        BuildCase(files: [".vscode/extensions/ext/package.json", ".vscode/extensions/ext/node_modules/x"],
                  folder: ".vscode/extensions/ext/node_modules", expected: nil),
        BuildCase(files: [".nvm/versions/node/v20/lib/package.json", ".nvm/versions/node/v20/lib/node_modules/npm/x"],
                  folder: ".nvm/versions/node/v20/lib/node_modules", expected: nil),
        BuildCase(files: [".venv/pyvenv.cfg"], folder: ".venv", expected: nil),
        BuildCase(files: ["Library/Application Support/Tool/package.json",
                          "Library/Application Support/Tool/node_modules/x"],
                  folder: "Library/Application Support/Tool/node_modules", expected: nil),
    ]

    @Test(arguments: buildCases)
    func detectsBuildFolders(_ testCase: BuildCase) throws {
        let home = try TempDir("home")
        for file in testCase.files { try home.write(file, bytes: 10) }
        let result = try reclassify(home, testCase.folder)
        #expect(result.buildFolder == testCase.expected)
        // Not reported on its own: either unmatched or inside another finding
        // (~/.vscode/extensions is an info rule).
        if testCase.expected == nil { #expect(result.isNothing || result.insideAncestor != nil) }
    }

    /// A marker counts only as a regular file. A folder or a symlink named
    /// package.json doesn't make the folder next to it a project, so its
    /// node_modules isn't a build folder.
    @Test func markersMustBeRegularFiles() throws {
        let home = try TempDir("home")
        try home.write("code/real/package.json", text: "{}")
        try home.write("code/real/node_modules/dep/index.js", bytes: 100)
        #expect(try reclassify(home, "code/real/node_modules").buildFolder == .nodeModules)

        try home.write("code/folder/package.json/inside.txt", text: "not a manifest")
        try home.write("code/folder/node_modules/dep/index.js", bytes: 100)
        #expect(try reclassify(home, "code/folder/node_modules").buildFolder == nil)

        try home.write("elsewhere/package.json", text: "{}")
        try home.mkdir("code/linked")
        try FileManager.default.createSymbolicLink(
            atPath: home.path("code/linked/package.json"), withDestinationPath: home.path("elsewhere/package.json"))
        try home.write("code/linked/node_modules/dep/index.js", bytes: 100)
        #expect(try reclassify(home, "code/linked/node_modules").buildFolder == nil)
    }

    @Test func nestedBuildFoldersBelongToTheOuterOne() throws {
        let home = try TempDir("home")
        try home.write("app/package.json", bytes: 10)
        try home.write("app/node_modules/dep/package.json", bytes: 10)
        try home.write("app/node_modules/dep/node_modules/x/i.js", bytes: 10)
        let result = try reclassify(home, "app/node_modules/dep/node_modules")
        #expect(result.insideAncestor == home.path("app/node_modules"))
    }

    @Test func projectLastChangeIgnoresBuildFolders() throws {
        let home = try TempDir("home")
        try home.write("app/package.json", bytes: 10)
        try home.write("app/src/index.js", bytes: 10)
        try home.write("app/node_modules/x/i.js", bytes: 10)
        try home.write("app/.DS_Store", bytes: 10)
        try home.touch("app/package.json", daysAgo: 30)
        try home.touch("app/src", daysAgo: 20)
        try home.touch("app/node_modules", daysAgo: 0)
        try home.touch("app/.DS_Store", daysAgo: 0)
        guard case .directory(.buildFolder(let match)?, _) = try reclassify(home, "app/node_modules") else {
            Issue.record("not a build folder")
            return
        }
        let age = Date().timeIntervalSince1970 - (match.projectLastChange ?? 0)
        #expect(abs(age - 20 * 86_400) < 120)
        #expect(match.projectName == "app")
    }

    @Test func rulesClaimTheirSubtree() throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.app/data/package.json", bytes: 10)
        try home.write("Library/Caches/com.example.app/data/node_modules/x", bytes: 10)
        try home.write("Library/Caches/com.apple.Safari/x", bytes: 10)
        try home.write("Downloads/project/package.json", bytes: 10)
        try home.write("Downloads/project/node_modules/x", bytes: 10)

        #expect(try reclassify(home, "Library/Caches/com.example.app").rule?.wildcard == "com.example.app")
        #expect(try reclassify(home, "Library/Caches/com.example.app/data/node_modules").insideAncestor
            == home.path("Library/Caches/com.example.app"))
        #expect(try reclassify(home, "Library/Caches/com.apple.Safari").isNothing)
        // Downloads is reported but doesn't hide what's inside it.
        #expect(try reclassify(home, "Downloads").rule?.rule.title == "Downloads")
        #expect(try reclassify(home, "Downloads/project/node_modules").buildFolder == .nodeModules)
    }

    @Test func libraryPackagesAndGitFoldersHideTheirContents() throws {
        let home = try TempDir("home")
        try home.write("Pictures/Photos Library.photoslibrary/originals/a.dmg", bytes: 10)
        try home.write("repo/.git/objects/pack/p.pack", bytes: 10)
        #expect(try reclassify(home, "Pictures/Photos Library.photoslibrary/originals").insideAncestor
            == home.path("Pictures/Photos Library.photoslibrary"))
        #expect(try reclassify(home, "repo/.git/objects").insideAncestor == home.path("repo/.git"))
    }

    @Test func skipsCloudStorageAndSymlinks() throws {
        let home = try TempDir("home")
        try home.write("Library/CloudStorage/Dropbox/file", bytes: 10)
        try home.write("real/Library/Caches/x/y", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: home.path("alias"), withDestinationPath: "real")
        guard case .notScanned = try reclassify(home, "Library/CloudStorage/Dropbox") else {
            Issue.record("CloudStorage was scanned")
            return
        }
        guard case .notScanned = try reclassify(home, "alias/Library") else {
            Issue.record("followed a symlink")
            return
        }
        guard case .missing = try reclassify(home, "nope") else {
            Issue.record("found a missing folder")
            return
        }
    }

    @Test func classifiesFiles() {
        func file(_ name: String, _ bytes: Int64) -> DirectoryEntry {
            DirectoryEntry(name: name, kind: .file, device: 1, inode: 1, linkCount: 1,
                           allocatedSize: bytes, modified: 0)
        }
        let home = Scope()
        #expect(Classifier.classifyFile(file("Xcode.xip", 150_000_000), in: home) == .installer)
        #expect(Classifier.classifyFile(file("Setup.PKG", 100_000_000), in: home) == .installer)
        #expect(Classifier.classifyFile(file("small.dmg", 99_000_000), in: home) == nil)
        #expect(Classifier.classifyFile(file("movie.mov", 1_000_000_000), in: home) == .largeFile)
        #expect(Classifier.classifyFile(file("movie.mov", 999_999_999), in: home) == nil)
        #expect(Classifier.classifyFile(file("disk.raw", 5_000_000_000), in: Scope(inLibrary: true)) == nil)
        #expect(Classifier.classifyFile(file("a.dmg", 5_000_000_000), in: Scope(claimed: true)) == nil)
    }
}
