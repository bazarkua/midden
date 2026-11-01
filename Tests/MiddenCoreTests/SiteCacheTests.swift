import Foundation
import Testing
@testable import MiddenCore

// Chromium browsers keep the Cache Storage of sites' service workers
// (offline copies of web apps) in each profile's Service Worker folder.
// It's site data, not the HTTP cache: Review, only with the browser quit,
// and only that folder, never the profile's cookies or other storage.

@Suite struct SiteCacheTests {
    static let chrome = "Library/Application Support/Google/Chrome"

    private func makeProfile(_ home: TempDir, _ profile: String) throws -> String {
        let root = "\(Self.chrome)/\(profile)"
        try home.write(root + "/Preferences", text: "{}")
        try home.write(root + "/Cookies", bytes: 20_000)
        try home.write(root + "/IndexedDB/https_mail.example.com_0.indexeddb.leveldb/000003.log", bytes: 20_000)
        try home.write(root + "/Local Storage/leveldb/000003.log", bytes: 20_000)
        try home.write(root + "/Service Worker/Database/000003.log", bytes: 20_000)
        try home.write(root + "/Service Worker/ScriptCache/index", bytes: 20_000)
        try home.write(root + "/Service Worker/CacheStorage/0a1b2c/index.txt", bytes: 200_000)
        return root
    }

    @Test func siteCachesAreReviewPerProfileAndKeepEverythingElse() async throws {
        let home = try TempDir("home")
        let main = try makeProfile(home, "Default")
        let work = try makeProfile(home, "Profile 1")
        // A browser started with --user-data-dir somewhere else.
        try home.write("chrome-profiles/agent/Default/Service Worker/CacheStorage/x/index.txt", bytes: 100_000)
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))

        for (root, profile) in [(main, "Default"), (work, "Profile 1")] {
            let finding = try #require(byPath[home.path(root + "/Service Worker/CacheStorage")], "\(profile)")
            #expect(finding.safety == .review)
            #expect(finding.title == "Google Chrome offline site data (\(profile))")
            #expect(finding.app?.bundleID == "com.google.Chrome")
            #expect(finding.explanation.contains("signed in"))
            #expect(finding.explanation.contains("Quit Google Chrome"))
        }
        #expect(byPath.keys.allSatisfy { !$0.hasPrefix(home.path("chrome-profiles")) })

        let result = try #require(await testCleaner(home).clean([home.path(main + "/Service Worker/CacheStorage")]).results.first)
        #expect(result.ok, "\(result)")
        for kept in ["Cookies", "IndexedDB", "Local Storage", "Preferences", "Service Worker/Database",
                     "Service Worker/ScriptCache/index"] {
            #expect(pathExists(home.path(main + "/" + kept)), "\(kept)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path(main + "/Service Worker/CacheStorage")).isEmpty)
        #expect(pathExists(home.path(work + "/Service Worker/CacheStorage/0a1b2c/index.txt")))
    }

    /// The browser running, or processes Midden can't fully read, keep it.
    @Test func aRunningBrowserOrUnknownProcessesKeepIt() async throws {
        let home = try TempDir("home")
        let main = try makeProfile(home, "Default")
        let target = home.path(main + "/Service Worker/CacheStorage")

        var running = testCleaner(home)
        running.runningApp = { $0.bundleID == "com.google.Chrome" ? "Google Chrome" : nil }
        let refused = try #require(await running.clean([target]).results.first)
        #expect(!refused.ok)
        #expect(refused.message?.contains("Google Chrome is running") == true, "\(refused)")

        let unknown = ProcessUsage(processes: [], failure: "the system wouldn't list processes (test)")
        let byPath = try await scanFindings(home, processes: unknown)
        #expect(byPath[target]?.safety == .info)
        var incomplete = testCleaner(home)
        incomplete.processUsage = { unknown }
        let result = try #require(await incomplete.clean([target]).results.first)
        #expect(!result.ok)
        #expect(pathExists(target + "/0a1b2c/index.txt"))
    }
}
