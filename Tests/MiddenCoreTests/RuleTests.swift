import Foundation
import Testing
@testable import MiddenCore

@Suite struct RuleTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var path: String
        var title: String?
        var safety: Safety?
        var wildcard: String? = nil
        var testDescription: String { path }
    }

    static let cases: [Case] = [
        Case(path: "Library/Developer/Xcode/DerivedData", title: "Xcode DerivedData", safety: .safe),
        Case(path: "Library/Developer/Xcode/iOS DeviceSupport", title: "{name}", safety: .safe),
        Case(path: "Library/Developer/Xcode/visionOS DeviceSupport", title: "{name}", safety: .safe),
        Case(path: "Library/Developer/Xcode/Archives", title: "Xcode archives", safety: .review),
        Case(path: "Library/Developer/CoreSimulator/Devices", title: "Simulators", safety: .info),
        Case(path: "Library/Containers/com.docker.docker", title: "Docker Desktop data", safety: .info),
        Case(path: ".npm/_cacache", title: "npm cache", safety: .safe),
        Case(path: ".gradle/wrapper/dists", title: "Gradle distributions", safety: .review),
        Case(path: "Library/pnpm/store", title: "pnpm store", safety: .info),
        // Specific ~/.cache rules win over the generic one.
        Case(path: ".cache/uv", title: "uv cache", safety: .safe),
        Case(path: ".cache/huggingface", title: "Hugging Face models", safety: .info),
        Case(path: ".cache/gitstatus", title: "~/.cache/{name}", safety: .review, wildcard: "gitstatus"),
        Case(path: "Library/Caches/pip", title: "pip cache", safety: .safe),
        Case(path: "Library/Caches/Homebrew", title: "Homebrew cache", safety: .info),
        Case(path: "Library/Caches/Homebrew/downloads", title: "Homebrew downloads", safety: .safe),
        // A cache folder Midden has no owner-specific rule for is Review:
        // being in Caches doesn't prove its owner rebuilds it.
        Case(path: "Library/Caches/com.spotify.client", title: "{app} cache", safety: .review,
             wildcard: "com.spotify.client"),
        Case(path: "Library/Caches/com.example.unknown", title: "{app} cache", safety: .review,
             wildcard: "com.example.unknown"),
        // Known owners earn Safe, each for a documented reason.
        Case(path: "Library/Caches/Yarn", title: "Yarn cache", safety: .safe),
        Case(path: "Library/Caches/go-build", title: "Go build cache", safety: .safe),
        Case(path: "Library/Caches/CocoaPods", title: "CocoaPods cache", safety: .safe),
        Case(path: "Library/Caches/Google/Chrome", title: "{app} disk cache", safety: .safe),
        Case(path: "Library/Caches/BraveSoftware/Brave-Browser", title: "{app} disk cache", safety: .safe),
        Case(path: "Library/Caches/Microsoft Edge", title: "{app} disk cache", safety: .safe),
        Case(path: "Library/Caches/Vivaldi", title: "{app} disk cache", safety: .safe),
        Case(path: "Library/Caches/Arc/User Data", title: "{app} disk cache", safety: .safe),
        Case(path: "Library/Caches/Dia/User Data", title: "{app} disk cache", safety: .safe),
        // Their parents, when another wildcard matches them, are containers.
        Case(path: "Library/Caches/Google", title: "{app} cache", safety: .review, wildcard: "Google"),
        Case(path: "Library/Application Support/Slack/Code Cache", title: "{app} web cache ({name})",
             safety: .safe, wildcard: "Slack"),
        // A cache folder holding another rule's folder is that rule's container.
        Case(path: "Library/Caches/org.R-project.R", title: "R package caches", safety: .info),
        Case(path: "Library/Caches/pypoetry", title: "Poetry", safety: .info),
        Case(path: "Library/Caches/pnpm", title: "pnpm cache", safety: .info),
        Case(path: "Library/Caches/llama.cpp", title: "llama.cpp models", safety: .info),
        Case(path: "Library/Caches/ms-playwright", title: "Playwright", safety: .info),
        Case(path: "Library/Caches/ms-playwright/chromium-1228", title: "Playwright browser ({name})", safety: .review),
        Case(path: "Library/Caches/ms-playwright-mcp", title: "Playwright MCP browser profiles", safety: .review),
        Case(path: "Library/Caches/pnpm/dlx", title: "pnpm dlx packages", safety: .review),
        Case(path: "Library/Caches/pnpm/metadata-v1.3", title: "pnpm metadata ({name})", safety: .safe),
        Case(path: "Library/Caches/pypoetry/virtualenvs", title: "Poetry virtual environments", safety: .review),
        Case(path: "Library/Caches/pypoetry/artifacts", title: "Poetry downloads ({name})", safety: .safe),
        Case(path: "Library/Caches/org.R-project.R/R/renv", title: "renv package cache", safety: .info),
        Case(path: "Library/Logs", title: "Logs", safety: .safe),
        Case(path: ".Trash", title: "Trash", safety: .review),
        Case(path: "Downloads", title: "Downloads", safety: .info),
        Case(path: ".ollama/models", title: "Ollama models", safety: .info),
        // AI coding tools: history is the user's, programs are the tools'.
        Case(path: ".claude/projects", title: "Claude Code conversations", safety: .info),
        Case(path: ".codex/sessions", title: "Codex conversations", safety: .info),
        Case(path: ".gemini/antigravity", title: "Antigravity conversations", safety: .info),
        Case(path: "Library/Application Support/Claude/vm_bundles", title: "Claude app virtual machine", safety: .info),
        Case(path: "Library/Application Support/Cursor/snapshots", title: "Cursor snapshots", safety: .info),
        Case(path: ".local/share/claude/versions", title: "Claude Code versions", safety: .info),
        Case(path: "Library/Application Support/Claude/Cache", title: "{app} web cache ({name})",
             safety: .safe, wildcard: "Claude"),
        // Worktrees in these folders are found one by one; a rule would hide them.
        Case(path: ".codex/worktrees", title: nil, safety: nil),
        Case(path: ".cursor/worktrees", title: nil, safety: nil),
        Case(path: ".claude", title: nil, safety: nil),
        // Apple's own folders are left alone.
        Case(path: "Library/Caches/com.apple.Safari", title: nil, safety: nil),
        Case(path: "Library/Caches/CloudKit", title: nil, safety: nil),
        Case(path: "Library/Application Support/com.apple.sharedfilelist/Cache", title: nil, safety: nil),
        // Not a match: parents, children and look-alikes.
        Case(path: "Library", title: nil, safety: nil),
        Case(path: "Library/Caches", title: nil, safety: nil),
        Case(path: "Library/Developer/Xcode/DerivedData/MyApp-abc", title: nil, safety: nil),
        Case(path: "Library/Application Support/Slack", title: nil, safety: nil),
        Case(path: "Work/Library/Caches/foo", title: nil, safety: nil),
        Case(path: ".cache", title: nil, safety: nil),
    ]

    @Test(arguments: cases)
    func matches(_ testCase: Case) {
        let match = RuleCatalog.match(testCase.path.split(separator: "/").map(String.init))
        #expect(match?.rule.title == testCase.title)
        #expect(match?.rule.safety == testCase.safety)
        if testCase.wildcard != nil {
            #expect(match?.wildcard == testCase.wildcard)
        }
    }

    @Test func downloadsDoesNotClaimItsSubtree() throws {
        let downloads = try #require(RuleCatalog.match(["Downloads"]))
        #expect(downloads.rule.claimsSubtree == false)
        #expect(RuleCatalog.match(["Library", "Logs"])?.rule.claimsSubtree == true)
    }

    @Test func everyRuleIsExplainedAndConsistent() {
        for rule in RuleCatalog.rules {
            #expect(!rule.explanation.isEmpty, "\(rule.paths)")
            #expect(rule.paths.allSatisfy { $0.split(separator: "/").filter { $0 == "*" }.count <= 1 })
            // Info findings are never deleted by Midden; the others always can be.
            #expect((rule.safety == .info) == !rule.action.isAutomatic, "\(rule.paths)")
        }
        #expect(RuleCatalog.maxDepth == 5)
    }

    @Test func namesApps() {
        #expect(Apps.app(forFolder: "com.tinyspeck.slackmacgap").hint.name == "Slack")
        let shipIt = Apps.app(forFolder: "com.tinyspeck.slackmacgap.ShipIt")
        #expect(shipIt.hint.bundleID == "com.tinyspeck.slackmacgap")
        #expect(shipIt.label == "Slack update")
        #expect(Apps.app(forFolder: "Google").hint.name == "Google Chrome")
        let unknown = Apps.app(forFolder: "org.example.not-installed")
        #expect(unknown.hint.bundleID == "org.example.not-installed")
        #expect(Apps.app(forFolder: "some-tool").hint == AppHint(name: "some-tool"))
        #expect(Apps.looksLikeBundleID("io.sentry") == false)
    }
}
