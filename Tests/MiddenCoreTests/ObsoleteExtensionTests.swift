import Foundation
import Testing
@testable import MiddenCore

// When VS Code updates an extension, it marks the old version in
// ~/.vscode/extensions/.obsolete and deletes it on its next start, but only
// a version it installed itself (with an installedTimestamp) whose key
// (lowercased publisher.name, version, target platform) is in the ledger.
// Midden offers exactly those, read again when cleaning, and only for VS
// Code: other editors' copies of this code aren't assumed to match.

@Suite struct ObsoleteExtensionTests {
    static let extensions = ".vscode/extensions"

    /// Writes an extension folder with its manifest.
    private func makeExtension(
        _ home: TempDir, folder: String, publisher: String, name: String, version: String,
        installed: Bool = true, platform: String? = nil
    ) throws {
        var metadata: [String: Any] = [:]
        if installed { metadata["installedTimestamp"] = 1_780_387_415_321 }
        if let platform { metadata["targetPlatform"] = platform }
        let manifest: [String: Any] = ["publisher": publisher, "name": name, "version": version, "__metadata": metadata]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try home.write("\(Self.extensions)/\(folder)/package.json", text: String(decoding: data, as: UTF8.self))
        try home.write("\(Self.extensions)/\(folder)/dist/extension.js", bytes: 100_000)
    }

    private func writeLedger(_ home: TempDir, _ text: String) throws {
        try home.write("\(Self.extensions)/.obsolete", text: text)
    }

    private func makeHome() throws -> TempDir {
        let home = try TempDir("home")
        try makeExtension(home, folder: "eamodio.gitlens-17.3.0", publisher: "eamodio", name: "gitlens", version: "17.3.0")
        try makeExtension(home, folder: "eamodio.gitlens-18.0.0", publisher: "eamodio", name: "gitlens", version: "18.0.0")
        try makeExtension(
            home, folder: "anthropic.claude-code-2.1.160-darwin-arm64", publisher: "Anthropic", name: "claude-code",
            version: "2.1.160", platform: "darwin-arm64")
        try makeExtension(home, folder: "ms-python.python-2024.1.0", publisher: "ms-python", name: "python", version: "2024.1.0")
        try makeExtension(home, folder: "acme.tool-1.0.0", publisher: "acme", name: "tool", version: "1.0.0")
        // Folder named for 1.0.0, manifest says 2.0.0.
        try makeExtension(home, folder: "acme.mismatch-1.0.0", publisher: "acme", name: "mismatch", version: "2.0.0")
        // Copied in by hand: no installedTimestamp.
        try makeExtension(home, folder: "acme.copied-1.0.0", publisher: "acme", name: "copied", version: "1.0.0", installed: false)
        try makeExtension(home, folder: "acme.profiled-1.0.0", publisher: "acme", name: "profiled", version: "1.0.0")
        try home.write("Documents/keep.txt", text: "mine")
        try writeLedger(home, """
            {"eamodio.gitlens-17.3.0": true, "anthropic.claude-code-2.1.160-darwin-arm64": true,
             "ms-python.python-2024.1.0": false, "acme.tool-1.0.0": "true",
             "acme.mismatch-1.0.0": true, "acme.copied-1.0.0": true, "acme.profiled-1.0.0": true,
             "../../Documents": true, "/etc": true}
            """)
        // Another profile still lists one of them.
        try home.write("Library/Application Support/Code/User/profiles/1a2b3c/extensions.json", text: """
            [{"identifier": {"id": "acme.profiled"}, "version": "1.0.0", "relativeLocation": "acme.profiled-1.0.0"}]
            """)
        return home
    }

    @Test func offersOnlyWhatVSCodeWouldDeleteItself() async throws {
        let home = try makeHome()
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        let offered = byPath.values.filter { $0.path.hasPrefix(home.path(Self.extensions) + "/") }.map(\.path).sorted()
        #expect(offered == ["anthropic.claude-code-2.1.160-darwin-arm64", "eamodio.gitlens-17.3.0"]
            .map { home.path("\(Self.extensions)/\($0)") })
        let old = try #require(byPath[home.path("\(Self.extensions)/eamodio.gitlens-17.3.0")])
        #expect(old.safety == .safe)
        #expect(old.app?.bundleID == "com.microsoft.VSCode")
        #expect(old.explanation.contains(".obsolete"))
        // The folder of every extension is never removable as a whole.
        let parent = try #require(byPath[home.path(Self.extensions)])
        #expect(!parent.action.isAutomatic)

        let everything = byPath.values.filter(\.action.isAutomatic).map(\.id)
        let results = await testCleaner(home).clean(everything).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        #expect(!pathExists(home.path("\(Self.extensions)/eamodio.gitlens-17.3.0")))
        for kept in ["eamodio.gitlens-18.0.0", "ms-python.python-2024.1.0", "acme.tool-1.0.0", "acme.mismatch-1.0.0",
                     "acme.copied-1.0.0", "acme.profiled-1.0.0"] {
            #expect(pathExists(home.path("\(Self.extensions)/\(kept)/package.json")), "\(kept)")
        }
        #expect(pathExists(home.path("Documents/keep.txt")))
    }

    @Test func aMalformedLedgerOrProfileOffersNothing() async throws {
        let home = try makeHome()
        try writeLedger(home, "{\"eamodio.gitlens-17.3.0\": true,")
        var byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        #expect(byPath.keys.filter { $0.hasPrefix(home.path(Self.extensions) + "/") }.isEmpty)

        try writeLedger(home, "{\"eamodio.gitlens-17.3.0\": true}")
        try home.write("Library/Application Support/Code/User/profiles/1a2b3c/extensions.json", text: "[{")
        byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        #expect(byPath.keys.filter { $0.hasPrefix(home.path(Self.extensions) + "/") }.isEmpty)
    }

    /// The ledger is read again when cleaning, and VS Code must be quit.
    /// A profiles folder Midden can't read may list any extension, so
    /// nothing is eligible: the scan offers no old version, and cleaning
    /// keeps the one that unreadable profile lists.
    @Test func anUnreadableProfilesFolderMakesNothingEligible() async throws {
        let home = try makeHome()
        let profiles = home.path("Library/Application Support/Code/User/profiles")
        chmod(profiles, 0o000)
        defer { chmod(profiles, 0o755) }
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        #expect(byPath.keys.filter { $0.hasPrefix(home.path(Self.extensions) + "/") }.isEmpty)

        let listed = home.path("\(Self.extensions)/acme.profiled-1.0.0")
        let results = await testCleaner(home).clean(
            [listed, home.path("\(Self.extensions)/eamodio.gitlens-17.3.0")]).results
        #expect(results.allSatisfy { !$0.ok }, "\(results)")
        chmod(profiles, 0o755)
        #expect(pathExists(listed + "/package.json"))
    }

    /// The profiles folder fails to list (EIO), or lists only partly: the
    /// inventory is unknown, so nothing is eligible.
    @Test func aFailedOrPartialProfileListingMakesNothingEligible() throws {
        let home = try makeHome()
        let extensions = home.path(Self.extensions)
        let entries = try DirectoryReader().entries(atPath: extensions)
        let failing: ObsoleteExtensions.Lister = { _ throws(POSIXError) in throw POSIXError(.EIO) }
        #expect(ObsoleteExtensions.eligible(extensions: extensions, entries: entries, home: home.path, list: failing).isEmpty)
        let partial: ObsoleteExtensions.Lister = { path throws(POSIXError) in
            var listing = try DirectoryReader().listing(atPath: path)
            listing.entries = []
            listing.markIncomplete(POSIXError(.EIO))
            return listing
        }
        #expect(ObsoleteExtensions.eligible(extensions: extensions, entries: entries, home: home.path, list: partial).isEmpty)
        // The same folder listed completely: the usual answer.
        #expect(ObsoleteExtensions.eligible(extensions: extensions, entries: entries, home: home.path)
            == ["eamodio.gitlens-17.3.0", "anthropic.claude-code-2.1.160-darwin-arm64"])
    }

    /// No profiles folder at all is confirmed absence: VS Code has only its
    /// default profile.
    @Test func noProfilesFolderStillWorks() throws {
        let home = try makeHome()
        try FileManager.default.removeItem(atPath: home.path("Library/Application Support/Code/User/profiles"))
        let extensions = home.path(Self.extensions)
        let entries = try DirectoryReader().entries(atPath: extensions)
        #expect(ObsoleteExtensions.eligible(extensions: extensions, entries: entries, home: home.path)
            == ["eamodio.gitlens-17.3.0", "anthropic.claude-code-2.1.160-darwin-arm64", "acme.profiled-1.0.0"])
    }

    @Test func checksTheLedgerAndVSCodeAgainWhenCleaning() async throws {
        let home = try makeHome()
        let target = home.path("\(Self.extensions)/eamodio.gitlens-17.3.0")
        var running = testCleaner(home)
        running.runningApp = { $0.bundleID == "com.microsoft.VSCode" ? "Visual Studio Code" : nil }
        let refused = try #require(await running.clean([target]).results.first)
        #expect(refused.message?.contains("Visual Studio Code is running") == true, "\(refused)")

        // VS Code reinstated it after the scan: it's no longer marked.
        try writeLedger(home, "{\"anthropic.claude-code-2.1.160-darwin-arm64\": true}")
        let result = try #require(await testCleaner(home).clean([target]).results.first)
        #expect(!result.ok)
        #expect(pathExists(target + "/package.json"))
    }
}
