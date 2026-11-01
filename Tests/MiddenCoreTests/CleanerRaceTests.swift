import Foundation
import Synchronization
import Testing
@testable import MiddenCore

// Time-of-check to time-of-use: the file system changes while the cleaner
// works on an item. Each test changes it at one exact stage (CleanStage,
// called by the engine) and checks that nothing outside home, and nothing
// put in the item's place, is deleted or moved.
//
// Cases the current engine loses are wrapped in withKnownIssue: they pass
// while the gap exists and fail once it's closed, so whoever builds the
// descriptor-based cleaner removes the wrapper. Every test deletes only
// inside its own temporary folders.

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// Runs `change` once, the first time the cleaner reaches `stage`, and
/// records whether the change succeeded: a passing check after a change
/// that never happened proves nothing.
private final class Trigger: Sendable {
    private let fired = Atomic<Bool>(false)
    private let worked = Atomic<Bool>(false)
    let stage: CleanStage
    let change: @Sendable () -> Bool
    init(at stage: CleanStage, _ change: @escaping @Sendable () -> Bool) {
        self.stage = stage
        self.change = change
    }
    func callAsFunction(_ reached: CleanStage, _ path: String) {
        guard reached == stage, !fired.exchange(true, ordering: .relaxed) else { return }
        worked.store(change(), ordering: .relaxed)
    }
    /// It ran, and every step of the change succeeded.
    var changed: Bool { fired.load(ordering: .relaxed) && worked.load(ordering: .relaxed) }
}

private func cleaner(_ home: TempDir, _ trigger: Trigger) -> Cleaner {
    var cleaner = Cleaner(home: home.url)
    let bin = home.path(".test-trash")
    cleaner.trash = { path in
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: bin + "/" + (path as NSString).lastPathComponent)
    }
    cleaner.barrier = { trigger($0, $1) }
    return cleaner
}

/// Replaces the folder at `path` with a symlink to `target`, keeping the
/// original next to it. True when both steps succeeded.
@Sendable private func swapForSymlink(_ path: String, to target: String) -> Bool {
    rename(path, path + ".moved") == 0 && symlink(target, path) == 0
}

/// Runs `body` as a known issue when `known` is true.
private func expectSafe(known: Bool, _ comment: Comment, _ body: () throws -> Void) rethrows {
    if known {
        withKnownIssue(comment) { try body() }
    } else {
        try body()
    }
}

@Suite struct CleanerRaceTests {
    /// ~/Library/Caches becomes a symlink to a folder outside home holding
    /// a folder of the same name as the cache being removed.
    @Test(arguments: CleanStage.allCases)
    func ancestorSwappedForASymlink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let sentinel = try outside.write("Caches/com.example.fake/precious.txt", text: "outside home")
        let caches = home.path("Library/Caches")
        let target = outside.path("Caches")
        let trigger = Trigger(at: stage) { swapForSymlink(caches, to: target) }

        let result = await cleaner(home, trigger).clean([home.path("Library/Caches/com.example.fake")]).results[0]
        #expect(trigger.changed)
        // Before deleting, nothing re-checks the ancestors: removeItem
        // follows the new symlink and deletes the folder outside home.
        expectSafe(known: stage == .beforeDelete, "ancestor swapped right before removeItem") {
            #expect(exists(sentinel))
            #expect(!result.ok)
        }
    }

    /// removeContents lists the folder by path, so a symlink swapped in for
    /// it, or for an ancestor, is followed. (Logs, which deletes only old
    /// files through descriptors, is tested in LogsTests.)
    @Test(arguments: CleanStage.allCases)
    func folderEmptiedInPlaceSwappedForASymlink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write(".cocoapods/repos/trunk/spec.json", bytes: 1_000)
        let sentinel = try outside.write("repos/precious.txt", text: "outside home")
        let repos = home.path(".cocoapods/repos")
        let target = outside.path("repos")
        let trigger = Trigger(at: stage) { swapForSymlink(repos, to: target) }

        let result = await cleaner(home, trigger).clean([repos]).results[0]
        #expect(trigger.changed)
        expectSafe(known: stage == .beforeDelete, "folder swapped right before removeContents") {
            #expect(exists(sentinel))
            #expect(!result.ok)
        }
    }

    /// The cache folder itself becomes a symlink: removeItem removes the
    /// link, never what it points to.
    @Test(arguments: CleanStage.allCases)
    func targetSwappedForASymlink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let sentinel = try outside.write("elsewhere/precious.txt", text: "outside home")
        let cache = home.path("Library/Caches/com.example.fake")
        let target = outside.path("elsewhere")
        let trigger = Trigger(at: stage) { swapForSymlink(cache, to: target) }

        _ = await cleaner(home, trigger).clean([cache])
        #expect(trigger.changed)
        #expect(exists(sentinel))
        // The original was moved aside, not deleted through the link.
        #expect(exists(cache + ".moved/blob"))
    }

    /// The folder is replaced by a file of the same name, say one the user
    /// moved there. It isn't what was approved, so it must stay.
    @Test(arguments: CleanStage.allCases)
    func targetReplacedByAFile(stage: CleanStage) async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let cache = home.path("Library/Caches/com.example.fake")
        let trigger = Trigger(at: stage) {
            rename(cache, cache + ".moved") == 0
                && FileManager.default.createFile(atPath: cache, contents: Data("not a cache".utf8))
        }

        let result = await cleaner(home, trigger).clean([cache]).results[0]
        #expect(trigger.changed)
        // Nothing checks the item's identity right before removeItem.
        expectSafe(known: stage == .beforeDelete, "replaced by a file right before removeItem") {
            #expect(exists(cache))
            #expect(!result.ok)
        }
    }

    /// A subfolder of the cache becomes a symlink to a folder outside
    /// home: removing the cache removes the link only.
    @Test(arguments: CleanStage.allCases)
    func childSwappedForASymlink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("Library/Caches/com.example.fake/data/blob", bytes: 10_000)
        let sentinel = try outside.write("data/precious.txt", text: "outside home")
        let child = home.path("Library/Caches/com.example.fake/data")
        let target = outside.path("data")
        let trigger = Trigger(at: stage) {
            (try? FileManager.default.removeItem(atPath: child)) != nil && symlink(target, child) == 0
        }

        _ = await cleaner(home, trigger).clean([home.path("Library/Caches/com.example.fake")])
        #expect(trigger.changed)
        #expect(exists(sentinel))
    }

    /// A file in the cache becomes a hard link to a file outside it:
    /// deleting the cache removes one name, and the other keeps the data.
    @Test(arguments: CleanStage.allCases)
    func fileBecomesAHardLink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let sentinel = try outside.write("precious.bin", bytes: 50_000)
        let blob = home.path("Library/Caches/com.example.fake/blob")
        let trigger = Trigger(at: stage) {
            unlink(blob) == 0 && link(sentinel, blob) == 0
        }

        _ = await cleaner(home, trigger).clean([home.path("Library/Caches/com.example.fake")])
        #expect(trigger.changed)
        #expect(exists(sentinel))
        #expect((try? Data(contentsOf: URL(fileURLWithPath: sentinel)))?.count == 50_000)
    }

    /// An installer moved to the Trash: its folder becomes a symlink to
    /// another folder holding a file of the same name. The Trash here is
    /// the test's stand-in (a move into a folder in the fake home), so this
    /// covers the path Midden hands it, not the real Trash's own handling.
    @Test(arguments: CleanStage.allCases)
    func installerFolderSwappedForASymlink(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("Downloads/Setup.pkg", bytes: 100_000_000)
        let sentinel = try outside.write("Downloads/Setup.pkg", text: "someone else's")
        let downloads = home.path("Downloads")
        let target = outside.path("Downloads")
        let trigger = Trigger(at: stage) { swapForSymlink(downloads, to: target) }

        _ = await cleaner(home, trigger).clean([home.path("Downloads/Setup.pkg")])
        #expect(trigger.changed)
        // Moved, not deleted, but moved out of a folder outside home.
        expectSafe(known: stage == .beforeDelete, "folder swapped right before moving to the Trash") {
            #expect(exists(sentinel))
        }
    }

    /// New work appears in a worktree while it's being cleaned: whatever
    /// the moment, git's own check refuses and the work stays.
    @Test(arguments: CleanStage.allCases)
    func worktreeGetsNewWork(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "task")
        let work = worktree + "/new-work.txt"
        let trigger = Trigger(at: stage) {
            FileManager.default.createFile(atPath: work, contents: Data("unsaved".utf8))
        }

        let result = await cleaner(home, trigger).clean([worktree]).results[0]
        #expect(trigger.changed)
        #expect(!result.ok)
        #expect(exists(work))
    }

    /// After validation, the folder is replaced by another folder of the
    /// same name holding something else. Same kind, same path: only its
    /// identity shows it isn't what was approved, and nothing checks that.
    /// (Before validation, the replacement is simply what gets validated.)
    @Test(arguments: [CleanStage.afterClaim, .beforeDelete])
    func targetReplacedByAnotherFolder(stage: CleanStage) async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let cache = home.path("Library/Caches/com.example.fake")
        let sentinel = cache + "/precious.txt"
        let trigger = Trigger(at: stage) {
            rename(cache, cache + ".moved") == 0 && mkdir(cache, 0o755) == 0
                && FileManager.default.createFile(atPath: sentinel, contents: Data("not a cache".utf8))
        }

        let result = await cleaner(home, trigger).clean([cache]).results[0]
        #expect(trigger.changed)
        expectSafe(known: true, "replaced by another folder after validation; no identity check") {
            #expect(exists(sentinel))
            #expect(!result.ok)
        }
    }

    /// An ignored file of the user's appears in a worktree after it was
    /// audited: `git worktree remove` deletes ignored files without asking,
    /// so it goes with the worktree.
    @Test(arguments: [CleanStage.afterClaim, .beforeDelete])
    func worktreeGetsIgnoredFilesAfterTheAudit(stage: CleanStage) async throws {
        let home = try TempDir("home")
        let repository = try makeRepository(home)
        try home.write("repo/.gitignore", text: ".env\n")
        try sh(["git", "-C", repository, "commit", "-q", "-am", "Ignore .env"])
        let worktree = try addWorktree(home, repository: repository, branch: "task")
        let secret = worktree + "/.env"
        let trigger = Trigger(at: stage) {
            FileManager.default.createFile(atPath: secret, contents: Data("API_KEY=only-copy".utf8))
        }

        let result = await cleaner(home, trigger).clean([worktree]).results[0]
        #expect(trigger.changed)
        expectSafe(known: true, "ignored file added after the audit; git removes it without asking") {
            #expect(exists(secret))
            #expect(!result.ok)
        }
    }
}
