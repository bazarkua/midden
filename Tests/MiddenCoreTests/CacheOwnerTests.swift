import Foundation
import Testing
@testable import MiddenCore

// ~/Library/Caches is where macOS asks apps to keep files they can
// recreate, but nothing enforces it: Poetry keeps virtual environments
// there, renv a package library, Playwright MCP signed-in browser
// profiles. So a folder there is Review unless Midden knows its owner and
// why the owner rebuilds it.

@Suite struct CacheOwnerTests {
    @Test func unknownCachesAreReviewAndKnownOwnersAreSafe() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.notes/offline/page.html", bytes: 300_000)
        try home.write("Library/Caches/Yarn/v6/npm-left-pad-1.3.0/package.json", bytes: 200_000)
        try home.write("Library/Caches/go-build/ab/abcdef-d", bytes: 200_000)
        try home.write("Library/Caches/CocoaPods/Pods/Release/Alamofire/x", bytes: 200_000)
        try home.write("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/f_000001", bytes: 400_000)
        try home.write("Library/Caches/Google/Updater/blob", bytes: 100_000)
        let (report, byPath) = try await scanAll(home)

        let unknown = try #require(byPath[home.path("Library/Caches/com.example.notes")])
        #expect(unknown.safety == .review)
        #expect(unknown.action == .removeDirectory)
        #expect(unknown.explanation.contains("doesn't know"))
        #expect(unknown.explanation.contains("Caches"))

        for known in ["Library/Caches/Yarn", "Library/Caches/go-build", "Library/Caches/CocoaPods",
                      "Library/Caches/Google/Chrome"] {
            let finding = try #require(byPath[home.path(known)], "\(known)")
            #expect(finding.safety == .safe, "\(known)")
            #expect(finding.action.isAutomatic, "\(known)")
        }
        let chrome = try #require(byPath[home.path("Library/Caches/Google/Chrome")])
        #expect(chrome.app?.bundleID == "com.google.Chrome")
        #expect(chrome.title == "Google Chrome disk cache")

        // Google's folder holds Chrome's cache, so it's a container: the
        // rest is listed, never removed with Chrome's cache inside.
        let google = try #require(byPath[home.path("Library/Caches/Google")])
        #expect(google.safety == .info)
        #expect(!google.action.isAutomatic)
        #expect(google.bytes + chrome.bytes == (try allocated(home.path("Library/Caches/Google"))))

        // "Clean safe items" picks only what has an owner Midden knows.
        let safe = report.findings.filter { $0.safety == .safe }.map(\.path)
        #expect(Set(safe) == Set(["Library/Caches/Yarn", "Library/Caches/go-build", "Library/Caches/CocoaPods",
                                  "Library/Caches/Google/Chrome"].map(home.path)))
    }

    /// An unknown cache is still the user's to clean: Review means the
    /// cleaner does it when asked, after the same checks.
    @Test func anUnknownCacheCanStillBeCleanedOnRequest() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.notes/blob", bytes: 100_000)
        let plan = try #require(await testCleaner(home).plan([home.path("Library/Caches/com.example.notes")]).first)
        #expect(plan.isApproved)
        #expect(plan.finding?.safety == .review)
    }
}
