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
        #expect(PrivacyProtected.skipped(
            in: ["Library", "Containers"], entries: folders(["com.apple.mail", "com.docker.docker"]))
            == ["com.apple.mail"])
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
        try home.write("Work/notes.txt", bytes: 50_000)

        var options = ScanOptions(home: home.url, minimumBytes: 1)
        options.fullDiskAccess = false
        let without = try await Scanner(options: options).scan()
        #expect(without.needsFullDiskAccess)
        #expect(without.unreadableCount == 3)
        let skipped = try ["Library/Mail", "Library/Group Containers/group.com.apple.notes",
                           "Library/Containers/com.apple.mail"].reduce(Int64(0)) { sum, folder in
            let du = try sh(["du", "-sk", home.path(folder)])
            return sum + Int64(du.split(separator: "\t").first ?? "0")! * 1024
        }
        let total = Int64(try sh(["du", "-sk", home.path]).split(separator: "\t").first ?? "0")! * 1024
        #expect(without.bytesScanned == total - skipped)

        options.fullDiskAccess = true
        let with = try await Scanner(options: options).scan()
        #expect(!with.needsFullDiskAccess)
        #expect(with.unreadableCount == 0)
        #expect(with.bytesScanned == total)
    }
}
