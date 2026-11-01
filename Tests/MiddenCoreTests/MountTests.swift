import Foundation
import Testing
@testable import MiddenCore

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// A 20 MB APFS disk image attached at a folder, detached when released.
private final class MountedDiskImage {
    let mountPoint: String
    private let image: String

    init(at mountPoint: String, imageFolder: TempDir) throws {
        self.mountPoint = mountPoint
        image = imageFolder.path("disk.dmg")
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "MiddenTest", image, "-quiet"])
        try Self.hdiutil(["attach", "-nobrowse", "-mountpoint", mountPoint, image, "-quiet"])
    }

    deinit {
        _ = try? Self.hdiutil(["detach", "-force", mountPoint, "-quiet"])
    }

    /// With a deadline: an hdiutil call once hung for minutes while another
    /// test run on the same Mac was making disk images too.
    private static func hdiutil(_ arguments: [String]) throws {
        let result = Command.run(["/usr/bin/hdiutil"] + arguments, timeout: 60)
        guard result.succeeded else {
            throw ShellError(command: "hdiutil \(arguments.joined(separator: " ")): \(result.message)", status: result.status)
        }
    }
}

@Suite(.serialized) struct MountTests {
    private func cleaner(_ home: TempDir) -> Cleaner {
        var cleaner = Cleaner(home: home.url)
        let bin = home.path(".test-trash")
        cleaner.trash = { path in
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: bin + "/" + (path as NSString).lastPathComponent)
        }
        return cleaner
    }

    /// FileManager.removeItem descends into a disk mounted inside the
    /// folder it removes, empties it, and only then fails with EBUSY on
    /// the mount point, leaving the folder half deleted.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func refusesAFolderWithADiskMountedInside() async throws {
        let home = try TempDir("home")
        let images = try TempDir("images")
        try home.write("Library/Caches/com.example.fake/data/blob", bytes: 200_000)
        try home.write("Library/Logs/old.log", bytes: 1_000)
        let cacheDisk = try MountedDiskImage(
            at: home.path("Library/Caches/com.example.fake/mnt"), imageFolder: images)
        let cacheSentinel = cacheDisk.mountPoint + "/sentinel.txt"
        try Data("on another disk".utf8).write(to: URL(fileURLWithPath: cacheSentinel))
        let logImages = try TempDir("images")
        let logsDisk = try MountedDiskImage(at: home.path("Library/Logs/mnt"), imageFolder: logImages)
        let logsSentinel = logsDisk.mountPoint + "/sentinel.txt"
        try Data("on another disk".utf8).write(to: URL(fileURLWithPath: logsSentinel))

        let plans = await cleaner(home).plan([home.path("Library/Caches/com.example.fake")])
        #expect(plans.first?.isApproved == false)
        #expect(plans.first?.refusal?.contains("mounted inside this folder") == true, "\(plans)")

        // removeDirectory and removeContents.
        let results = await cleaner(home).clean([
            home.path("Library/Caches/com.example.fake"), home.path("Library/Logs"),
        ]).results
        for result in results {
            #expect(!result.ok, "\(result.id)")
            #expect(result.message?.contains("Eject it first") == true, "\(result.message ?? "")")
        }
        #expect(exists(cacheSentinel))
        #expect(exists(logsSentinel))
        #expect(exists(home.path("Library/Caches/com.example.fake/data/blob")))
        #expect(exists(home.path("Library/Logs/old.log")))
    }

    /// Attached through another spelling of the same folder (/var is a
    /// symlink to /private/var): still found, still refused.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func refusesAMountAttachedThroughAnotherSpelling() async throws {
        let home = try TempDir("home")
        let images = try TempDir("images")
        try home.write("Library/Caches/com.example.fake/data/blob", bytes: 200_000)
        try #require(home.path.hasPrefix("/private/var/"))
        let spelled = String(home.path.dropFirst("/private".count)) + "/Library/Caches/com.example.fake/mnt"
        let disk = try MountedDiskImage(at: spelled, imageFolder: images)
        let sentinel = disk.mountPoint + "/sentinel.txt"
        try Data("on another disk".utf8).write(to: URL(fileURLWithPath: sentinel))

        let result = await cleaner(home).clean([home.path("Library/Caches/com.example.fake")]).results[0]
        #expect(!result.ok)
        #expect(result.message?.contains("Eject it first") == true, "\(result.message ?? "")")
        #expect(exists(sentinel))
    }

    /// The mount table spells a mount point another way than the item's
    /// canonical path: equivalence is established, or the clean refused.
    @Test func comparesMountPointsAfterResolvingThem() throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/mnt/x", bytes: 10)
        let cache = home.path("Library/Caches/com.example.fake")
        let spelled = String(cache.dropFirst("/private".count)) + "/mnt"
        let resolved = try #require(CleanEngine.canonicalMountPoints(["/", spelled]))
        #expect(CleanEngine.mountRefusal(cache, mountPoints: resolved)?.contains("mounted inside") == true)
        // A mount point whose folder can't be resolved can't be compared.
        #expect(CleanEngine.canonicalMountPoints(["/", home.path("gone/mnt")]) == nil)
    }

    /// Every way the volume check can fail to verify ends in a refusal,
    /// with the cache and its contents untouched.
    @Test func refusesWhenTheVolumeCantBeVerified() throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        let cache = home.path("Library/Caches/com.example.fake")
        let homePath = home.path

        var noTable = try CleanEngine(home: home.url)
        noTable.mountPoints = { nil }
        var noDevice = try CleanEngine(home: home.url)
        noDevice.deviceOf = { $0 == cache ? nil : CleanEngine.lstatDevice($0) }
        var noHomeDevice = try CleanEngine(home: home.url)
        noHomeDevice.deviceOf = { $0 == homePath ? nil : CleanEngine.lstatDevice($0) }

        for (engine, expected) in [
            (noTable, "list of mounted disks"), (noDevice, "which disk"), (noHomeDevice, "which disk"),
        ] {
            let result = engine.clean(cache)
            #expect(!result.ok)
            #expect(result.message?.contains(expected) == true, "\(result.message ?? "")")
            #expect(exists(cache + "/blob"))
        }
    }

    @Test func mountTableCheck() {
        let home = "/Users/me"
        let mounts = ["/", "/System/Volumes/Data", "/Users/me/Library/Caches/app/mnt", "/Users/me/Downloads/disk"]
        func refusal(_ path: String) -> String? {
            CleanEngine.mountRefusal(path, mountPoints: mounts)
        }
        #expect(refusal(home + "/Library/Caches/app")?.contains("mounted inside this folder") == true)
        #expect(refusal(home + "/Library/Caches")?.contains("mounted inside this folder") == true)
        #expect(refusal(home + "/Downloads/disk")?.contains("mounted at this folder") == true)
        // A sibling whose name only starts the same isn't affected.
        #expect(refusal(home + "/Downloads/disk2") == nil)
        #expect(refusal(home + "/Library/Caches/app2") == nil)
        #expect(refusal(home + "/Library/Logs") == nil)
    }
}
