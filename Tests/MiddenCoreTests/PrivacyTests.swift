import Foundation
import Testing
@testable import MiddenCore

@Suite struct PrivacyTests {
    private func folders(_ names: [String]) -> [DirectoryEntry] {
        names.map {
            DirectoryEntry(name: $0, kind: .directory, device: 1, inode: 1, linkCount: 1, allocatedSize: 0, modified: 0)
        }
    }

    @Test func listsProtectedSubfolders() {
        #expect(PrivacyProtected.skipped(in: [], entries: folders([".Trash", "Library", "Work"])) == [".Trash"])
        #expect(PrivacyProtected.skipped(in: ["Library"], entries: folders(["Mail", "Caches", "Messages", "Logs"]))
            == ["Mail", "Messages"])
        // Every other app's container: reading one can ask for permission.
        #expect(PrivacyProtected.skipped(
            in: ["Library", "Containers"], entries: folders(["com.apple.mail", "com.docker.docker"]))
            == ["com.apple.mail", "com.docker.docker"])
        // Folders macOS asks about with a prompt.
        #expect(PrivacyProtected.skipped(
            in: [], entries: folders(["Desktop", "Documents", "Downloads", "Music", "Movies", "Work"]))
            == ["Desktop", "Documents", "Downloads", "Music"])
        #expect(PrivacyProtected.skipped(in: ["Movies"], entries: folders(["TV", "Clips"])) == ["TV"])
        #expect(PrivacyProtected.skipped(in: ["Library"], entries: folders(["Mobile Documents", "Logs"]))
            == ["Mobile Documents"])
        #expect(PrivacyProtected.skipped(
            in: ["Library", "Group Containers"], entries: folders(["group.com.apple.notes", "UBF8T346G9.Office"]))
            == ["group.com.apple.notes", "UBF8T346G9.Office"])
        #expect(PrivacyProtected.skipped(
            in: ["Pictures"], entries: folders(["Photos Library.photoslibrary", "Screenshots"]))
            == ["Photos Library.photoslibrary"])
        #expect(PrivacyProtected.skipped(
            in: ["Library", "Application Support", "Google"], entries: folders(["Chrome", "DriveFS"]))
            == ["Chrome"])
        // Files are never "folders to skip".
        let file = DirectoryEntry(name: "Mail", kind: .file, device: 1, inode: 1, linkCount: 1, allocatedSize: 0, modified: 0)
        #expect(PrivacyProtected.skipped(in: ["Library"], entries: [file]).isEmpty)
    }

    @Test func skipsProtectedFoldersWithoutFullDiskAccess() async throws {
        let home = try TempDir("home")
        try home.write("Library/Mail/V10/mail.emlx", bytes: 300_000)
        try home.write("Library/Group Containers/group.com.apple.notes/db", bytes: 200_000)
        try home.write("Library/Containers/com.apple.mail/Data/x", bytes: 100_000)
        try home.write("Library/Containers/com.docker.docker/Data/vm.raw", bytes: 400_000)
        try home.write("Documents/thesis.pages", bytes: 60_000)
        try home.write("Work/notes.txt", bytes: 50_000)
        try home.write("Work/locked/secret.txt", bytes: 1_000)
        chmod(home.path("Work/locked"), 0o000)
        defer { chmod(home.path("Work/locked"), 0o755) }

        var options = ScanOptions(home: home.url, minimumBytes: 1)
        options.fullDiskAccess = false
        // This fake home stands in for the account's own.
        options.privacyHome = home.path
        let without = try await Scanner(options: options).scan()
        #expect(without.needsFullDiskAccess)
        #expect(without.skippedWithoutFullDiskAccess == 5)
        #expect(without.readErrors == 1)
        #expect(without.unreadableCount == 6)
        #expect(without.skippedFolders == [
            "Documents", "Library/Mail", "Library/Containers/com.apple.mail",
            "Library/Containers/com.docker.docker", "Library/Group Containers/group.com.apple.notes",
        ])
        let skipped = try ["Library/Mail", "Library/Group Containers/group.com.apple.notes",
                           "Library/Containers/com.apple.mail", "Library/Containers/com.docker.docker",
                           "Documents"].reduce(Int64(0)) { sum, folder in
            let du = try sh(["du", "-sk", home.path(folder)])
            return sum + Int64(du.split(separator: "\t").first ?? "0")! * 1024
        }
        // du can't read the locked folder either, so it counts the same.
        let total = Int64(((try? sh(["du", "-sk", home.path])) ?? duIgnoringErrors(home.path))
            .split(separator: "\t").first ?? "0")! * 1024
        #expect(without.bytesScanned == total - skipped)

        options.fullDiskAccess = true
        let with = try await Scanner(options: options).scan()
        #expect(!with.needsFullDiskAccess)
        #expect(with.skippedWithoutFullDiskAccess == 0)
        #expect(with.skippedFolders.isEmpty)
        #expect(with.readErrors == 1)
        #expect(with.unreadableCount == 1)
        #expect(with.bytesScanned == total)
    }
}

@Suite struct ProtectedLocationTests {
    /// A folder with ordinary Desktop, Documents and Downloads folders, as
    /// `midden scan --home <any folder>` might get.
    private func arbitraryRoot() throws -> TempDir {
        let root = try TempDir("project-tree")
        try root.write("Desktop/notes.txt", bytes: 10_000)
        try root.write("Documents/spec.md", bytes: 10_000)
        try root.write("Downloads/Setup.pkg", bytes: 100_000_000)
        return root
    }

    /// Only the account's own Desktop, Documents and Downloads are
    /// protected. Without Full Disk Access, the same names anywhere else
    /// were skipped as if they were.
    @Test func foldersNamedLikeProtectedOnesElsewhereAreScanned() async throws {
        let root = try arbitraryRoot()
        let account = try TempDir("account")
        var options = ScanOptions(home: root.url, minimumBytes: 1)
        options.fullDiskAccess = false
        options.privacyHome = account.path
        let report = try await Scanner(options: options).scan()
        #expect(report.skippedFolders.isEmpty, "\(report.skippedFolders)")
        #expect(report.skippedWithoutFullDiskAccess == 0)
        #expect(report.findings.contains { $0.path == root.path("Downloads/Setup.pkg") })
    }

    /// The default path, with nothing forced: the real account is probed,
    /// and a folder outside it has nothing protected in it, whatever the
    /// answer.
    @Test func theDefaultPathProbesTheRealAccount() async throws {
        let root = try arbitraryRoot()
        let report = try await Scanner(options: ScanOptions(home: root.url, minimumBytes: 1)).scan()
        #expect(report.skippedFolders.isEmpty, "\(report.skippedFolders)")
        #expect(report.findings.contains { $0.path == root.path("Downloads/Setup.pkg") })
    }

    /// Rooted inside a protected location, without Full Disk Access, the
    /// scan doesn't open it (that would raise the prompt it exists to
    /// avoid). Rooted in a folder that holds protected ones, it skips those
    /// by where they really are.
    @Test func scansRootedInsideTheAccountFollowTheAccountsLocations() async throws {
        let account = try TempDir("account")
        try account.write("Documents/project/main.swift", bytes: 10_000)
        try account.write("Library/Mail/V10/mail.emlx", bytes: 10_000)
        try account.write("Library/Logs/app.log", bytes: 10_000)
        var options = ScanOptions(home: account.url.appendingPathComponent("Documents/project"), minimumBytes: 1)
        options.fullDiskAccess = false
        options.privacyHome = account.path
        await #expect(throws: MiddenError.unreadable(path: account.path("Documents/project"), code: EPERM)) {
            try await Scanner(options: options).scan()
        }

        options.home = account.url.appendingPathComponent("Library")
        let library = try await Scanner(options: options).scan()
        #expect(library.skippedFolders == ["Mail"])
        options.fullDiskAccess = true
        let granted = try await Scanner(options: options).scan()
        #expect(granted.skippedFolders.isEmpty)
    }
}

/// `du -sk` output even when du exits 1 because a folder can't be read.
private func duIgnoringErrors(_ path: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sk", path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
