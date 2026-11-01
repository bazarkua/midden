import Foundation
import Synchronization
import Testing
@testable import MiddenCore

// ~/Library/Logs: only regular files older than 7 days are deleted, and
// every folder stays exactly as it was. macOS doesn't recreate some of
// them: after another cleaner removed DiagnosticReports, the next crash
// report couldn't be saved (osanalyticshelper was denied creating it).
// Every test deletes only inside a fake home in a temporary folder.

/// Allocated bytes of one file, without following a symlink.
private func fileBytes(_ path: String) -> Int64 {
    var info = stat()
    return lstat(path, &info) == 0 ? Int64(info.st_blocks) * 512 : -1
}

/// What must not change about a kept folder.
private struct FolderIdentity: Equatable {
    var device: Int32
    var inode: UInt64
    var mode: mode_t
    var owner: uid_t
    var acl: String?

    init?(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        mode = info.st_mode
        owner = info.st_uid
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            if let text = acl_to_text(acl, nil) {
                self.acl = String(cString: text)
                acl_free(UnsafeMutableRawPointer(text))
            }
        }
    }
}

/// Sets a file's modification time to `seconds` since 1970.
private func setModified(_ path: String, _ seconds: Double) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
}

@Suite struct LogsTests {
    static let logs = "Library/Logs"
    static let folders = [
        "", "DiagnosticReports", "DiagnosticReports/Retired", "App", "App/rotated", "Empty", "Odd",
    ]

    /// A Logs folder with every kind of entry. Returns the files that must
    /// be deleted and those that must stay.
    private func makeLogs(_ home: TempDir, outside: TempDir) throws -> (old: [String], kept: [String]) {
        let old = [
            "DiagnosticReports/App-2026-10-01.ips", "DiagnosticReports/Retired/App-2026-09-01.ips",
            "App/app.log.1", "App/rotated/app.log.2",
        ].map { home.path("\(Self.logs)/\($0)") }
        for path in old {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x5A, count: 40_000))
            try home.touch(String(path.dropFirst(home.path.count + 1)), daysAgo: 10)
        }
        let recent = try home.write("\(Self.logs)/DiagnosticReports/App-today.ips", bytes: 30_000)
        let current = try home.write("\(Self.logs)/App/app.log", bytes: 30_000)
        let sixDays = try home.write("\(Self.logs)/App/app.log.0", bytes: 30_000)
        try home.touch("\(Self.logs)/App/app.log.0", daysAgo: 6.9)
        let future = try home.write("\(Self.logs)/Odd/future.log", bytes: 30_000)
        try setModified(future, Date().timeIntervalSince1970 + 30 * 86_400)
        let unknownAge = try home.write("\(Self.logs)/Odd/epoch.log", bytes: 30_000)
        try setModified(unknownAge, 0)
        try home.mkdir("\(Self.logs)/Empty")
        // A file with a second name elsewhere: deleting this name frees
        // nothing and the other name keeps the data, so it's left alone.
        let shared = try home.write("keep/shared.log", bytes: 30_000)
        let linked = home.path("\(Self.logs)/App/shared.log")
        try FileManager.default.linkItem(atPath: shared, toPath: linked)
        try home.touch("keep/shared.log", daysAgo: 30)
        // Symlinks to old files and folders outside: never followed, and
        // the links themselves aren't regular files.
        let target = try outside.write("old/target.log", bytes: 30_000)
        try outside.touch("old/target.log", daysAgo: 30)
        try outside.touch("old", daysAgo: 30)
        try FileManager.default.createSymbolicLink(
            atPath: home.path("\(Self.logs)/App/link.log"), withDestinationPath: target)
        try FileManager.default.createSymbolicLink(
            atPath: home.path("\(Self.logs)/linked-folder"), withDestinationPath: outside.path("old"))
        // DiagnosticReports is group-writable with an ACL on a real Mac.
        chmod(home.path("\(Self.logs)/DiagnosticReports"), 0o770)
        try sh(["chmod", "+a", "\(NSUserName()) allow list,add_file,search,delete_child",
                home.path("\(Self.logs)/DiagnosticReports")])
        return (old, [recent, current, sixDays, future, unknownAge, linked, target, shared])
    }

    @Test func deletesOnlyOldFilesAndKeepsEveryFolder() async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        let (old, kept) = try makeLogs(home, outside: outside)
        let identities = Self.folders.map { FolderIdentity(home.path("\(Self.logs)/\($0)")) }
        #expect(identities[1]?.acl?.contains("allow") == true, "the fixture's ACL wasn't set")
        let eligible = old.reduce(0) { $0 + fileBytes($1) }

        let (_, byPath) = try await scanAll(home)
        let finding = try #require(byPath[home.path(Self.logs)])
        #expect(finding.safety == .safe)
        #expect(finding.action == .removeContents)
        // The size is what cleaning deletes, not the whole folder.
        #expect(finding.bytes == eligible)
        #expect(finding.breakdown.reduce(0) { $0 + $1.bytes } == eligible)
        #expect(finding.explanation.contains("7 days"))
        #expect(finding.explanation.contains("DiagnosticReports"))

        let plan = try #require(await testCleaner(home).plan([home.path(Self.logs)]).first)
        #expect(plan.isApproved, "\(plan)")
        #expect(plan.finding?.bytes == eligible)

        let result = try #require(await testCleaner(home).clean([home.path(Self.logs)]).results.first)
        #expect(result.ok, "\(result)")
        #expect(result.freedBytes == eligible)
        for path in old { #expect(!pathExists(path), "\(path)") }
        for path in kept { #expect(pathExists(path), "\(path)") }
        #expect(pathExists(home.path("\(Self.logs)/App/link.log")))
        #expect(pathExists(home.path("\(Self.logs)/linked-folder")))
        // Every folder is the same folder: same inode, mode, owner and ACL.
        #expect(Self.folders.map { FolderIdentity(home.path("\(Self.logs)/\($0)")) } == identities)
    }

    /// A folder Midden can't open, and a file it can't delete, are left
    /// alone and reported; everything else old still goes.
    @Test func reportsWhatPermissionsKeepIt() async throws {
        let home = try TempDir("home")
        let locked = try home.write("\(Self.logs)/Locked/old.log", bytes: 10_000)
        let readOnly = try home.write("\(Self.logs)/ReadOnly/old.log", bytes: 10_000)
        let free = try home.write("\(Self.logs)/Free/old.log", bytes: 10_000)
        for relative in ["Locked/old.log", "ReadOnly/old.log", "Free/old.log"] {
            try home.touch("\(Self.logs)/\(relative)", daysAgo: 10)
        }
        chmod(home.path("\(Self.logs)/Locked"), 0o000)
        chmod(home.path("\(Self.logs)/ReadOnly"), 0o555)
        defer {
            chmod(home.path("\(Self.logs)/Locked"), 0o755)
            chmod(home.path("\(Self.logs)/ReadOnly"), 0o755)
        }

        let freeBytes = fileBytes(free)
        let result = try #require(await testCleaner(home).clean([home.path(Self.logs)]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("couldn't") == true, "\(result)")
        #expect(result.freedBytes == freeBytes)
        #expect(!pathExists(free))
        chmod(home.path("\(Self.logs)/Locked"), 0o755)
        #expect(pathExists(locked))
        #expect(pathExists(readOnly))
    }

    /// Logs, or the folder above it, becomes a symlink to a folder outside
    /// home holding old files, at each stage of cleaning. The folder is
    /// opened with O_NOFOLLOW and everything below through descriptors,
    /// so nothing outside home is deleted at any stage.
    @Test(arguments: CleanStage.allCases, [false, true])
    func neverFollowsASymlinkSwappedIn(stage: CleanStage, ancestor: Bool) async throws {
        let home = try TempDir("home")
        let outside = try TempDir("outside")
        try home.write("\(Self.logs)/App/old.log", bytes: 10_000)
        try home.touch("\(Self.logs)/App/old.log", daysAgo: 10)
        let sentinel = try outside.write("Library/Logs/App/precious.log", bytes: 10_000)
        try outside.touch("Library/Logs/App/precious.log", daysAgo: 30)
        let swapped = home.path(ancestor ? "Library" : Self.logs)
        let target = outside.path(ancestor ? "Library" : Self.logs)
        let fired = Mutex(false)
        var cleaner = testCleaner(home)
        cleaner.barrier = { reached, _ in
            guard reached == stage, !fired.withLock({ $0 }) else { return }
            fired.withLock { $0 = true }
            rename(swapped, swapped + ".moved")
            symlink(target, swapped)
        }
        let result = try #require(await cleaner.clean([home.path(Self.logs)]).results.first)
        #expect(fired.withLock { $0 })
        #expect(pathExists(sentinel), "\(result)")
        #expect(pathExists(swapped + ".moved"))
    }

    /// A folder whose entry is on another device, as a disk mounted inside
    /// Logs is, isn't entered, while old files beside it go. (A real disk
    /// image mounted after the last check is in MountTests, on request.)
    @Test func neverEntersAFolderOnAnotherDevice() throws {
        let home = try TempDir("home")
        let mounted = try home.write("\(Self.logs)/mnt/old.log", bytes: 10_000)
        let beside = try home.write("\(Self.logs)/App/old.log", bytes: 10_000)
        try home.touch("\(Self.logs)/mnt/old.log", daysAgo: 10)
        try home.touch("\(Self.logs)/App/old.log", daysAgo: 10)
        var policy = AgedFiles(minimumAge: 7 * 86_400, now: Date())
        policy.lister = { fd, reader throws(POSIXError) in
            var listing = try reader.listing(directory: fd)
            listing.entries = listing.entries.map { entry in
                var entry = entry
                if entry.name == "mnt" { entry.device &+= 1 }
                return entry
            }
            return listing
        }
        let survey = try #require(policy.survey(home.path(Self.logs)))
        #expect(survey.files == 1)
        let removed = try #require(policy.remove(home.path(Self.logs), home: home.path))
        #expect(removed.files == 1)
        #expect(pathExists(mounted))
        #expect(!pathExists(beside))
    }

    /// A listing that stops partway: what was listed is handled, what
    /// wasn't stays, and the pass says it was incomplete.
    @Test func partialListingDeletesOnlyWhatWasListed() throws {
        let home = try TempDir("home")
        let root = home.path(Self.logs)
        let paths = try (0..<6).map { index in
            try home.write("\(Self.logs)/App/old-\(index).log", bytes: 10_000)
        }
        for index in 0..<6 { try home.touch("\(Self.logs)/App/old-\(index).log", daysAgo: 10) }
        var policy = AgedFiles(minimumAge: 7 * 86_400, now: Date())
        policy.lister = { fd, reader throws(POSIXError) in
            var listing = try reader.listing(directory: fd)
            // App's listing loses everything after its first three files.
            if listing.entries.contains(where: { $0.name.hasPrefix("old-") }) {
                let files = listing.entries.filter { $0.name.hasPrefix("old-") }.sorted { $0.name < $1.name }
                listing.entries = Array(files.prefix(3))
                listing.markIncomplete(POSIXError(.EIO))
            }
            return listing
        }
        let survey = try #require(policy.survey(root))
        #expect(survey.files == 3)
        #expect(survey.unreadableFolders == 1)
        let removed = try #require(policy.remove(root, home: home.path))
        #expect(removed.files == 3)
        #expect(removed.unreadableFolders == 1)
        #expect(paths.filter(pathExists).count == 3)
        #expect(pathExists(home.path("\(Self.logs)/App")))
    }

    /// A file that becomes recent, or is replaced by another file, between
    /// the listing and the delete is kept: each file is checked again
    /// through its folder's descriptor right before it's unlinked.
    @Test func checksEachFileAgainBeforeDeletingIt() throws {
        let home = try TempDir("home")
        let root = home.path(Self.logs)
        let touched = try home.write("\(Self.logs)/App/touched.log", bytes: 10_000)
        let replaced = try home.write("\(Self.logs)/App/replaced.log", bytes: 10_000)
        try home.touch("\(Self.logs)/App/touched.log", daysAgo: 10)
        try home.touch("\(Self.logs)/App/replaced.log", daysAgo: 10)
        var policy = AgedFiles(minimumAge: 7 * 86_400, now: Date())
        policy.lister = { fd, reader throws(POSIXError) in
            let listing = try reader.listing(directory: fd)
            if listing.entries.contains(where: { $0.name == "touched.log" }) {
                // After the listing: one file is written to, one replaced.
                _ = try? FileHandle(forWritingTo: URL(fileURLWithPath: touched)).write(contentsOf: Data("new".utf8))
                try? FileManager.default.removeItem(atPath: replaced)
                FileManager.default.createFile(atPath: replaced, contents: Data(repeating: 1, count: 10))
                try? setModified(replaced, Date().timeIntervalSince1970 - 30 * 86_400)
            }
            return listing
        }
        let removed = try #require(policy.remove(root, home: home.path))
        #expect(removed.files == 0)
        #expect(pathExists(touched))
        #expect(pathExists(replaced))
    }
}
