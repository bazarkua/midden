import Foundation
import Testing
@testable import MiddenCore

// Xcode's DeviceSupport folders: one folder of debug symbols per OS
// version copied from a device. The newest version per platform is most
// likely the one on the device in use, so it stays Review, older ones are
// Safe, and the folder holding them is never removed as a whole.

@Suite struct DeviceSupportTests {
    static let iOS = "Library/Developer/Xcode/iOS DeviceSupport"
    static let watchOS = "Library/Developer/Xcode/watchOS DeviceSupport"

    private func makeVersions(_ home: TempDir, _ platform: String, _ names: [String]) throws {
        for name in names {
            try home.write("\(platform)/\(name)/Symbols/usr/lib/dyld", bytes: 100_000)
        }
    }

    private func safety(_ byPath: [String: Finding], _ home: TempDir, _ platform: String, _ name: String) -> Safety? {
        byPath[home.path("\(platform)/\(name)")]?.safety
    }

    @Test func newestVersionPerPlatformIsReviewAndOlderOnesSafe() async throws {
        let home = try TempDir("home")
        // 17.10 is newer than 17.9: versions compare by number, not text.
        try makeVersions(home, Self.iOS, ["16.4.1 (20E252)", "17.9 (21H1)", "iPhone15,2 17.10 (21X5) arm64e"])
        try makeVersions(home, Self.watchOS, ["10.0 (21R356)", "Watch6,1 9.6.3 (20U502)"])
        let (_, byPath) = try await scanAll(home)

        #expect(safety(byPath, home, Self.iOS, "iPhone15,2 17.10 (21X5) arm64e") == .review)
        #expect(safety(byPath, home, Self.iOS, "17.9 (21H1)") == .safe)
        #expect(safety(byPath, home, Self.iOS, "16.4.1 (20E252)") == .safe)
        #expect(safety(byPath, home, Self.watchOS, "10.0 (21R356)") == .review)
        #expect(safety(byPath, home, Self.watchOS, "Watch6,1 9.6.3 (20U502)") == .safe)
        // The folders holding them can't take every version with them.
        for platform in [Self.iOS, Self.watchOS] {
            let plan = try #require(await testCleaner(home).plan([home.path(platform)]).first)
            #expect(!plan.isApproved, "\(platform)")
        }
    }

    /// Two folders of the same version (different builds or devices) are
    /// both the newest. A name Midden can't read leaves the newest unknown,
    /// so every version stays Review.
    @Test func tiesAndUnreadableNamesStayReview() async throws {
        let home = try TempDir("home")
        try makeVersions(home, Self.iOS, ["17.0 (21A329)", "iPad13,1 17.0.0 (21A331)", "16.0 (20A362)"])
        try makeVersions(home, Self.watchOS, ["10.0 (21R356)", "9.0 (20R362)", "Latest"])
        let (_, byPath) = try await scanAll(home)

        #expect(safety(byPath, home, Self.iOS, "17.0 (21A329)") == .review)
        #expect(safety(byPath, home, Self.iOS, "iPad13,1 17.0.0 (21A331)") == .review)
        #expect(safety(byPath, home, Self.iOS, "16.0 (20A362)") == .safe)
        for name in ["10.0 (21R356)", "9.0 (20R362)", "Latest"] {
            #expect(safety(byPath, home, Self.watchOS, name) == .review, "\(name)")
        }
    }

    /// The cleaner decides from the folder as it is now: a newer version
    /// copied after the scan makes the old newest Safe, and the newest
    /// going away makes the next one Review.
    @Test func versionsChangingAfterTheScanAreSeenWhenCleaning() async throws {
        let home = try TempDir("home")
        try makeVersions(home, Self.iOS, ["16.0 (20A362)", "17.0 (21A329)"])
        let (_, byPath) = try await scanAll(home)
        #expect(safety(byPath, home, Self.iOS, "17.0 (21A329)") == .review)

        try makeVersions(home, Self.iOS, ["18.0 (22A3354)"])
        let plans = await testCleaner(home).plan(["17.0 (21A329)", "18.0 (22A3354)"].map { home.path("\(Self.iOS)/\($0)") })
        #expect(plans.map { $0.finding?.safety } == [.safe, .review])

        try FileManager.default.removeItem(atPath: home.path("\(Self.iOS)/18.0 (22A3354)"))
        try FileManager.default.removeItem(atPath: home.path("\(Self.iOS)/17.0 (21A329)"))
        let last = try #require(await testCleaner(home).plan([home.path("\(Self.iOS)/16.0 (20A362)")]).first)
        #expect(last.finding?.safety == .review)
    }

    /// When the DeviceSupport folder's listing is incomplete, the newest
    /// version can't be known, and nothing in it is classified.
    @Test func anIncompleteListingClassifiesNoVersion() throws {
        let home = try TempDir("home")
        try makeVersions(home, Self.iOS, ["16.0 (20A362)", "17.0 (21A329)"])
        let folder = home.path(Self.iOS)
        let walker = Walker(root: home.path, delegate: ScanDelegate(), lister: { path, reader throws(POSIXError) in
            var listing = try reader.listing(atPath: path)
            if path == folder {
                // The newest version's entry is the one that went missing.
                listing.entries.removeAll { $0.name.hasPrefix("17.0") }
                listing.markIncomplete(POSIXError(.EIO))
            }
            return listing
        })
        let walk = try walker.run()
        let marked = walk.marked.filter { $0.mark != nil }.map(\.path)
        #expect(!marked.contains { $0.hasPrefix(folder + "/") }, "\(marked)")
    }

    @Test func parsesVersionFolderNames() {
        typealias V = DeviceSupportVersions
        #expect(V.parse("17.0 (21A329)")?.numbers == [17, 0])
        #expect(V.parse("17.0 (21A329) arm64e")?.build == "21A329")
        #expect(V.parse("iPhone15,2 17.4.1 (21E236)")?.numbers == [17, 4, 1])
        #expect(V.parse("Latest") == nil)
        #expect(V.parse("17.0") == nil)
        #expect(V.parse("17.x (21A329)") == nil)
        #expect(V.parse("17.10 (1)")! > V.parse("17.9 (1)")!)
        #expect(V.parse("17.0 (1)")!.sameVersion(as: V.parse("17.0.0 (2)")!))
    }
}
