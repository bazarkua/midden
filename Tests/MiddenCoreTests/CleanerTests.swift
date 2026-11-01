import Foundation
import Testing
@testable import MiddenCore

// Every test here deletes only inside a fake home in a temporary folder.

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

@Suite struct CleanerTests {
    /// Cleans with the Trash replaced by a folder inside the fake home, so
    /// nothing reaches the real Trash.
    private func clean(_ home: TempDir, _ ids: [String]) async -> [CleanResult] {
        await cleaner(home).clean(ids).results
    }

    private func cleaner(_ home: TempDir) -> Cleaner {
        var cleaner = Cleaner(home: home.url)
        let bin = home.path(".test-trash")
        cleaner.trash = { path in
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: bin + "/" + (path as NSString).lastPathComponent)
        }
        return cleaner
    }

    @Test func deletesAFakeCache() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/data/blob", bytes: 200_000)
        try home.write("Library/Logs/old.log", bytes: 1_000)
        try home.write("Library/Logs/DiagnosticReports/crash.ips", bytes: 1_000)

        let plans = await Cleaner(home: home.url).plan([home.path("Library/Caches/com.example.fake")])
        #expect(plans.first?.isApproved == true)
        #expect((plans.first?.finding?.bytes ?? 0) >= 200_000)

        let summary = await Cleaner(home: home.url).clean([
            home.path("Library/Caches/com.example.fake"), home.path("Library/Logs"),
        ])
        #expect(summary.results.allSatisfy { $0.ok })
        #expect(summary.freeBefore > 0)
        // Measured from what was deleted, not from the volume's free space.
        #expect(summary.results[0].freedBytes >= 200_000)
        #expect(summary.results[1].freedBytes >= 2_000)
        #expect(!exists(home.path("Library/Caches/com.example.fake")))
        // removeContents keeps the folder itself.
        #expect(exists(home.path("Library/Logs")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path("Library/Logs")).isEmpty)
    }

    @Test func deletesAnOldBuildFolderAndTrashesAnInstaller() async throws {
        let home = try TempDir("home")
        try home.write("code/app/package.json", text: "{}")
        try home.write("code/app/node_modules/dep/index.js", bytes: 1_000)
        try home.write("Downloads/Setup.pkg", bytes: 100_000_000)
        let results = await clean(home, [home.path("code/app/node_modules"), home.path("Downloads/Setup.pkg")])
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        #expect(!results[0].movedToTrash)
        // Your own files go to the Trash, where they still take space.
        #expect(results[1].movedToTrash)
        #expect(results[1].freedBytes == 0)
        #expect(!exists(home.path("code/app/node_modules")))
        #expect(!exists(home.path("Downloads/Setup.pkg")))
        #expect(exists(home.path(".test-trash/Setup.pkg")))
        #expect(exists(home.path("code/app/package.json")))
    }

    @Test func refusesWhatItShouldNotTouch() async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try outside.write("Library/Caches/com.example.fake/blob", bytes: 1_000)
        try home.write("Library/Caches/com.example.fake/data/blob", bytes: 1_000)
        try home.write("Documents/thesis/draft.txt", text: "precious")
        try home.write("Downloads/photo.jpg", bytes: 1_000)
        try home.write("Downloads/small.dmg", bytes: 1_000)
        try FileManager.default.createSymbolicLink(
            atPath: home.path("Library/Caches/com.example.link"),
            withDestinationPath: home.path("Documents/thesis"))
        try FileManager.default.createSymbolicLink(
            atPath: home.path("alias"), withDestinationPath: home.path("Library"))

        let refused: [String: String] = [
            outside.path("Library/Caches/com.example.fake"): "outside your home",
            home.path("Library/Caches/com.example.link"): "symbolic link",
            home.path("alias/Caches/com.example.fake"): "symbolic link",
            home.path("Library/Caches/../../Documents/thesis"): "canonical",
            home.path("Library/Caches/./com.example.fake"): "canonical",
            home.path("Library/Caches//com.example.fake"): "canonical",
            "Library/Caches/com.example.fake": "canonical",
            home.path("Documents/thesis"): "doesn't recognize",
            home.path("Downloads/small.dmg"): "doesn't recognize",
            home.path("Downloads"): "doesn't delete this itself",
            home.path("Library/Caches/com.example.fake/data"): "inside",
            home.path("Library/Caches/com.example.gone"): "no longer exists",
            home.path(""): "outside your home",
            "sim:not-a-uuid": "Not a simulator id",
        ]
        let results = await clean(home, Array(refused.keys))
        for result in results {
            #expect(!result.ok, "\(result.id)")
            #expect(result.freedBytes == 0)
            let expected = refused[result.id] ?? "?"
            #expect(result.message?.contains(expected) == true, "\(result.id): \(result.message ?? "")")
        }
        #expect(exists(outside.path("Library/Caches/com.example.fake/blob")))
        #expect(exists(home.path("Library/Caches/com.example.fake/data/blob")))
        #expect(exists(home.path("Documents/thesis/draft.txt")))
        #expect(exists(home.path("Downloads/photo.jpg")))
    }

    @Test func removesAWorktreeAndKeepsItsBranch() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "agent-task")
        try home.write("worktrees/agent-task/node_modules/dep/index.js", bytes: 1_000)
        try home.write("worktrees/agent-task/feature.txt", text: "done")
        try sh(["git", "-C", worktree, "add", "feature.txt"])
        try sh(["git", "-C", worktree, "commit", "-q", "-m", "Finish the task"])

        let results = await clean(home, [worktree])
        #expect(results.first?.ok == true, "\(results)")
        #expect(!exists(worktree))
        #expect(try sh(["git", "-C", repository, "branch", "--list", "agent-task"]).contains("agent-task"))
        #expect(try sh(["git", "-C", repository, "log", "-1", "--format=%s", "agent-task"]) == "Finish the task")
        #expect(!(try sh(["git", "-C", repository, "worktree", "list"]).contains(worktree)))
    }

    @Test func refusesADirtyWorktree() async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "wip")
        try home.write("worktrees/wip/unsaved.txt", text: "work in progress")

        let results = await clean(home, [worktree])
        #expect(results.first?.ok == false)
        #expect(results.first?.message?.contains("Commit or discard the changes") == true, "\(results)")
        #expect(exists(home.path("worktrees/wip/unsaved.txt")))
    }
}
