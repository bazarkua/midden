import Foundation
import Testing
@testable import MiddenCore

// The descriptor-based deletion walks (Logs' old files, SwiftPM's clean)
// hold one descriptor per level. They stop at a fixed depth and treat a
// failed open, out of descriptors included, as something they couldn't
// do, and say so; what they could do is still done.

@Suite struct DeletionLimitTests {
    /// Writes an old file at each level of a chain of folders.
    private func chain(_ home: TempDir, _ root: String, levels: Int) throws -> [String] {
        var folder = root
        var files: [String] = []
        for level in 1...levels {
            folder += "/l\(level)"
            let file = try home.write("\(folder)/old.log", bytes: 1_000)
            try home.touch("\(folder)/old.log", daysAgo: 10)
            files.append(file)
        }
        return files
    }

    @Test func oldFilesStopAtTheDepthLimit() throws {
        let home = try TempDir("home")
        let files = try chain(home, "Library/Logs", levels: 4)
        var policy = AgedFiles(minimumAge: 7 * 86_400, now: Date())
        policy.maxDepth = 2
        let outcome = try #require(policy.remove(home.path("Library/Logs"), home: home.path))
        #expect(outcome.files == 2)
        #expect(outcome.tooDeep == 1)
        #expect(files.map(pathExists) == [false, false, true, true])
    }

    @Test func oldFilesInAFolderThatCantBeOpenedStay() throws {
        let home = try TempDir("home")
        let files = try chain(home, "Library/Logs", levels: 3)
        var policy = AgedFiles(minimumAge: 7 * 86_400, now: Date())
        policy.open = { parent, name in
            if name == "l2" {
                errno = EMFILE
                return -1
            }
            return openFolder(parent, name)
        }
        let outcome = try #require(policy.remove(home.path("Library/Logs"), home: home.path))
        #expect(outcome.unreadableFolders == 1)
        #expect(files.map(pathExists) == [false, true, true])
    }

    /// Through the cleaner: a folder nested deeper than the limit keeps its
    /// old file, and the result says why instead of reporting success.
    @Test func cleaningLogsReportsWhatWasTooDeep() async throws {
        let home = try TempDir("home")
        let files = try chain(home, "Library/Logs", levels: deletionDepthLimit + 2)
        let result = try #require(await testCleaner(home).clean([home.path("Library/Logs")]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("didn't go into 1 folder") == true, "\(result)")
        #expect(!pathExists(files[0]))
        #expect(pathExists(files.last!))
    }

    @Test func removingAFolderStopsAtTheDepthLimit() throws {
        let home = try TempDir("home")
        let deep = try home.write("build/x/y/z/file.o", bytes: 1_000)
        let shallow = try home.write("build/x/top.o", bytes: 1_000)
        let other = try home.write("build/other/file.o", bytes: 1_000)
        let fd = try DirectoryReader.openDirectory(home.path("build"))
        defer { close(fd) }
        var tree = TreeRemoval()
        tree.maxDepth = 2
        tree.remove("x", in: fd)
        tree.remove("other", in: fd)
        #expect(tree.failures == ["z"])
        #expect(pathExists(deep))
        #expect(!pathExists(shallow))
        #expect(!pathExists(other))
        #expect(pathExists(home.path("build/x/y")))
    }

    @Test func removingAFolderThatCantBeOpenedFailsHonestly() throws {
        let home = try TempDir("home")
        let kept = try home.write("build/x/y/file.o", bytes: 1_000)
        let fd = try DirectoryReader.openDirectory(home.path("build"))
        defer { close(fd) }
        var tree = TreeRemoval()
        tree.open = { parent, name in
            if name == "y" {
                errno = EMFILE
                return -1
            }
            return openFolder(parent, name)
        }
        tree.remove("x", in: fd)
        #expect(tree.failures == ["y"])
        #expect(pathExists(kept))
    }
}
