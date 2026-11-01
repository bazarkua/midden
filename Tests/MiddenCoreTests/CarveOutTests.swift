import Foundation
import Testing
@testable import MiddenCore

// Data that tools keep inside cache folders but that isn't a cache, carved
// out of the folders around it. Each test scans, plans and cleans a fake
// home in a temporary folder.

/// Scans a fake home with a given process listing, reporting everything.
func scanFindings(_ home: TempDir, processes: ProcessUsage? = nil) async throws -> [String: Finding] {
    var options = ScanOptions.fakeHome(home, minimumBytes: 1)
    if let processes { options.processUsage = { processes } }
    let report = try await Scanner(options: options).scan()
    return Dictionary(report.findings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
}

/// Runs `/bin/sh script` from `directory` until the returned process is
/// terminated. The script's path appears only in the arguments.
func runScript(_ script: String, from directory: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    try process.run()
    return process
}

@Suite struct CarveOutTests {
    // MARK: pnpm dlx

    static let pnpm = "Library/Caches/pnpm"
    static let dlxTool = pnpm + "/dlx/5f2a/node_modules/.bin/tool"

    private func makePnpmHome() throws -> TempDir {
        let home = try TempDir("home")
        try home.write(Self.dlxTool, text: "#!/bin/sh\nwhile :; do sleep 0.2; done\n")
        chmod(home.path(Self.dlxTool), 0o755)
        try home.write(Self.pnpm + "/dlx/5f2a/node_modules/tool/index.js", bytes: 200_000)
        try home.write(Self.pnpm + "/metadata-v1.3/registry.npmjs.org/left-pad.json", bytes: 100_000)
        // Untouched for two months. That says nothing about whether a
        // running program uses it.
        for path in ["/dlx/5f2a/node_modules/tool/index.js", "/dlx/5f2a/node_modules/tool", "/dlx/5f2a/node_modules",
                     "/dlx/5f2a", "/dlx"] {
            try home.touch(Self.pnpm + path, daysAgo: 60)
        }
        return home
    }

    @Test func pnpmDlxIsReviewAndItsParentIsNeverRemoved() async throws {
        let home = try makePnpmHome()
        let byPath = try await scanFindings(home)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        // Old, idle and still only Review: its age isn't evidence of disuse.
        #expect(dlx.safety == .review)
        #expect(dlx.action == .removeDirectory)
        #expect(dlx.checks.map(\.id) == ["inUse"])
        #expect(dlx.checks.first?.passed == true)
        #expect(byPath[home.path(Self.pnpm + "/metadata-v1.3")]?.safety == .safe)

        for result in await testCleaner(home).clean([home.path(Self.pnpm), home.path("Library/Caches")]).results {
            #expect(!result.ok, "\(result.id)")
        }
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    /// A command pnpm dlx installed is running, started from another
    /// folder: its script's path is only in the process's arguments.
    @Test func aRunningDlxCommandKeepsItsFolder() async throws {
        let home = try makePnpmHome()
        let process = try runScript(home.path(Self.dlxTool), from: home.path)
        defer { process.terminate() }

        let byPath = try await scanFindings(home)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        #expect(dlx.safety == .info)
        #expect(!dlx.action.isAutomatic)
        #expect(dlx.checks.first?.passed == false)
        #expect(dlx.checks.first?.detail.contains("pid \(process.processIdentifier)") == true, "\(dlx.checks)")

        let result = try #require(await testCleaner(home).clean([home.path(Self.pnpm + "/dlx")]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("Quit") == true, "\(result)")
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    /// Without a complete process listing, nothing counts as unused.
    @Test func unknownProcessStateKeepsDlx() async throws {
        let home = try makePnpmHome()
        let unknown = ProcessUsage(processes: [], failure: "the system wouldn't list processes (test)")
        let byPath = try await scanFindings(home, processes: unknown)
        let dlx = try #require(byPath[home.path(Self.pnpm + "/dlx")])
        #expect(dlx.safety == .info)
        #expect(dlx.checks.first?.detail.contains("Couldn't check") == true, "\(dlx.checks)")

        var cleaner = testCleaner(home)
        cleaner.processUsage = { unknown }
        let result = try #require(await cleaner.clean([home.path(Self.pnpm + "/dlx")]).results.first)
        #expect(!result.ok)
        #expect(pathExists(home.path(Self.dlxTool)))
    }

    /// The kernel keeps only 16 bytes of a command's name ("Spotify
    /// Helper ("), so "Quit ..." names the app the program belongs to.
    @Test func namesTheAppToQuit() {
        func process(_ executable: String, _ command: String) -> ProcessUsage.Process {
            ProcessUsage.Process(pid: 1, command: command, directory: "/", executable: executable, arguments: [])
        }
        let helper = process(
            "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper (Renderer).app/Contents/MacOS/Spotify Helper (Renderer)",
            "Spotify Helper (")
        #expect(helper.displayName == "Spotify")
        #expect(process("/bin/sh", "sh").displayName == "sh")
        #expect(process("", "curl").displayName == "curl")

        let finding = Finding(
            id: "/x", category: .appCaches, title: "t", path: "/x", group: "g", bytes: 1, safety: .review,
            explanation: "e", action: .removeDirectory)
        let users = ProcessUsage(processes: [helper, process("/Applications/Spotify.app/Contents/MacOS/Spotify", "Spotify")]
            .map { var p = $0; p.directory = "/x"; return p })
        let checked = Findings.checkingUse(finding, users)
        #expect(checked.action == .manual("Quit Spotify first, then scan again."))
    }

    @Test func argumentsNameAFolderOnlyAtPathBoundaries() {
        let path = "/Users/me/Library/Caches/pnpm/dlx"
        #expect(ProcessUsage.mentions(path, path))
        #expect(ProcessUsage.mentions(path + "/x/bin.js", path))
        #expect(ProcessUsage.mentions("--user-data-dir=" + path, path))
        #expect(ProcessUsage.mentions("--cache=" + path + "/y", path))
        #expect(!ProcessUsage.mentions(path + "2/x", path))
        #expect(!ProcessUsage.mentions("/private" + path, path))
    }

    // MARK: Playwright MCP

    /// Makes a Chromium profile folder: what a browser started with
    /// `--user-data-dir` writes.
    private func makeProfile(_ home: TempDir, _ relative: String) throws {
        try home.write(relative + "/Local State", text: "{}")
        try home.write(relative + "/Default/Cookies", bytes: 50_000)
        try home.write(relative + "/Default/Login Data", bytes: 50_000)
    }

    /// Playwright MCP keeps signed-in browser profiles in
    /// ~/Library/Caches/ms-playwright/mcp-<channel>-<hash> (its README) or
    /// ~/Library/Caches/ms-playwright-mcp (seen on a Mac), next to the
    /// browsers Playwright downloads. Profiles are Review with a warning
    /// about sign-ins, apart from the browsers; a profile anywhere else in
    /// Caches gets the same warning, and one outside any rule is left alone.
    @Test func playwrightProfilesAreSeparateFromItsBrowsers() async throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/ms-playwright/chromium-1228/chrome-mac/Chromium.app/x", bytes: 300_000)
        try home.write("Library/Caches/ms-playwright/__dirlock", bytes: 10)
        try makeProfile(home, "Library/Caches/ms-playwright/mcp-chrome-ab12cd3")
        try makeProfile(home, "Library/Caches/ms-playwright-mcp/mcp-chrome-1ab718c")
        try makeProfile(home, "Library/Caches/my-agent-profile")
        try makeProfile(home, "work/profiles/agent")
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))

        let browser = try #require(byPath[home.path("Library/Caches/ms-playwright/chromium-1228")])
        #expect(browser.safety == .review)
        #expect(browser.explanation.contains("npx playwright install"))
        #expect(!browser.explanation.contains("signs"))
        for profile in ["Library/Caches/ms-playwright/mcp-chrome-ab12cd3", "Library/Caches/ms-playwright-mcp",
                        "Library/Caches/my-agent-profile"] {
            let finding = try #require(byPath[home.path(profile)], "\(profile)")
            #expect(finding.safety == .review, "\(profile)")
            #expect(finding.explanation.contains("signs"), "\(profile)")
            #expect(finding.explanation.contains("Quit"), "\(profile)")
            #expect(finding.checks.map(\.id) == ["inUse"], "\(profile)")
        }
        let parent = try #require(byPath[home.path("Library/Caches/ms-playwright")])
        #expect(parent.safety == .info)
        #expect(byPath.keys.allSatisfy { !$0.hasPrefix(home.path("work")) })

        // Cleaning the browser leaves the profile beside it; the folder
        // holding both is never removed.
        let results = await testCleaner(home).clean(
            ["Library/Caches/ms-playwright/chromium-1228", "Library/Caches/ms-playwright"].map(home.path)).results
        #expect(results.map(\.ok) == [true, false], "\(results)")
        #expect(pathExists(home.path("Library/Caches/ms-playwright/mcp-chrome-ab12cd3/Default/Login Data")))
    }

    /// A browser running on the profile names it in its arguments.
    @Test func aBrowserRunningOnAProfileKeepsIt() async throws {
        let home = try TempDir("home")
        let profile = "Library/Caches/ms-playwright/mcp-chrome-ab12cd3"
        try makeProfile(home, profile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do sleep 0.2; done", "chrome", "--user-data-dir=" + home.path(profile)]
        try process.run()
        defer { process.terminate() }

        let plan = try #require(await testCleaner(home).plan([home.path(profile)]).first)
        #expect(!plan.isApproved)
        #expect(plan.finding?.checks.first?.passed == false)
        #expect(plan.refusal?.contains("Quit") == true, "\(plan)")
        let result = try #require(await testCleaner(home).clean([home.path(profile)]).results.first)
        #expect(!result.ok)
        #expect(pathExists(home.path(profile + "/Default/Login Data")))
    }

    // MARK: Homebrew

    static let brew = "Library/Caches/Homebrew"

    private func makeBrewHome() throws -> TempDir {
        let home = try TempDir("home")
        let bottle = try home.write(
            Self.brew + "/downloads/0123abcd--wget-1.24.5.arm64_sequoia.bottle.tar.gz", bytes: 300_000)
        try home.write(Self.brew + "/api/formula.jws.json", bytes: 200_000)
        try home.write(Self.brew + "/bootsnap/0a/1b2c", bytes: 100_000)
        try home.mkdir(Self.brew + "/Cask")
        try FileManager.default.createSymbolicLink(
            atPath: home.path(Self.brew + "/wget--1.24.5.arm64_sequoia.bottle.tar.gz"), withDestinationPath: bottle)
        return home
    }

    /// Only downloads/ is cleaned: wiping api/ and bootsnap/ makes the next
    /// `brew` run slow, and they aren't downloads of packages.
    @Test func homebrewCleansOnlyItsDownloads() async throws {
        let home = try makeBrewHome()
        let byPath = try await scanFindings(home, processes: ProcessUsage(processes: []))
        let downloads = try #require(byPath[home.path(Self.brew + "/downloads")])
        #expect(downloads.safety == .safe)
        #expect(downloads.action == .removeContents)
        #expect(!downloads.explanation.contains("cleanup -s"))
        let parent = try #require(byPath[home.path(Self.brew)])
        #expect(parent.safety == .info)

        let results = await testCleaner(home).clean([Self.brew + "/downloads", Self.brew].map(home.path)).results
        #expect(results.map(\.ok) == [true, false], "\(results)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path(Self.brew + "/downloads")).isEmpty)
        #expect(pathExists(home.path(Self.brew + "/api/formula.jws.json")))
        #expect(pathExists(home.path(Self.brew + "/bootsnap/0a/1b2c")))
        #expect(pathExists(home.path(Self.brew + "/Cask")))
        #expect(pathExists(home.path(Self.brew + "/wget--1.24.5.arm64_sequoia.bottle.tar.gz")))
    }

    /// An unfinished download is Review; one a program is writing keeps
    /// the folder until it's done.
    @Test func anActiveHomebrewDownloadKeepsTheFolder() async throws {
        let home = try makeBrewHome()
        let partial = try home.write(Self.brew + "/downloads/4567cdef--node-22.1.0.bottle.tar.gz.incomplete", bytes: 50_000)
        let idle = try await scanFindings(home, processes: ProcessUsage(processes: []))
        let unfinished = try #require(idle[home.path(Self.brew + "/downloads")])
        #expect(unfinished.safety == .review)
        #expect(unfinished.explanation.contains("unfinished"))

        // curl writing the download names it in its arguments.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do sleep 0.2; done", "curl", "--output", partial]
        try process.run()
        defer { process.terminate() }
        let result = try #require(await testCleaner(home).clean([home.path(Self.brew + "/downloads")]).results.first)
        #expect(!result.ok)
        #expect(result.message?.contains("Quit") == true, "\(result)")
        #expect(pathExists(partial))
    }

    // MARK: Electron and Chromium apps in Application Support

    /// An Electron app's user data folder as Chromium writes it, with its
    /// caches and its site data.
    private func makeElectronApp(_ home: TempDir, _ name: String, layout: Bool = true) throws -> String {
        let root = "Library/Application Support/" + name
        if layout {
            try home.write(root + "/Preferences", text: "{}")
            try home.write(root + "/Network Persistent State", text: "{}")
            try home.write(root + "/TransportSecurity", text: "{}")
        }
        try home.write(root + "/Cookies", bytes: 20_000)
        try home.write(root + "/Login Data", bytes: 20_000)
        try home.write(root + "/IndexedDB/https_app.example.com_0.indexeddb.leveldb/000003.log", bytes: 20_000)
        try home.write(root + "/Local Storage/leveldb/000003.log", bytes: 20_000)
        try home.write(root + "/Cache/Cache_Data/f_000001", bytes: 200_000)
        try home.write(root + "/Code Cache/js/abcdef", bytes: 100_000)
        try home.write(root + "/GPUCache/data_1", bytes: 50_000)
        return root
    }

    @Test func appSupportCachesAreSafeOnlyForKnownElectronLayouts() async throws {
        let home = try TempDir("home")
        let slack = try makeElectronApp(home, "Slack")
        let code = try makeElectronApp(home, "Code")
        try home.write(code + "/CachedData/0f1e2d3c/chrome/js/a", bytes: 100_000)
        let unknown = try makeElectronApp(home, "G HUB")
        // Named like a known app, without Chromium's files: not that app.
        let lookalike = try makeElectronApp(home, "Claude", layout: false)
        // Unrelated: cache-like names and one Chromium file by coincidence.
        try home.write("Library/Application Support/MyNotes/Cache/notes.db", bytes: 100_000)
        try home.write("Library/Application Support/MyNotes/GPUCache/x", bytes: 10_000)
        try home.write("Library/Application Support/MyNotes/Preferences", text: "{}")
        let byPath = try await scanFindings(home)

        for cache in ["Cache", "Code Cache", "GPUCache"] {
            #expect(byPath[home.path(slack + "/" + cache)]?.safety == .safe, "\(cache)")
            #expect(byPath[home.path(code + "/" + cache)]?.safety == .safe, "\(cache)")
            let other = byPath[home.path(unknown + "/" + cache)]
            #expect(other?.safety == .review, "\(cache)")
            #expect(other?.explanation.contains("doesn't know") == true, "\(cache)")
            #expect(byPath[home.path(lookalike + "/" + cache)] == nil, "\(cache)")
        }
        #expect(byPath[home.path(code + "/CachedData")]?.safety == .safe)
        #expect(byPath[home.path(slack + "/Cache")]?.app?.bundleID == "com.tinyspeck.slackmacgap")
        #expect(byPath[home.path("Library/Application Support/MyNotes/Cache")] == nil)

        // Cleaning the caches keeps the app's sign-ins and site data.
        let caches = ["Cache", "Code Cache", "GPUCache"].map { home.path(slack + "/" + $0) }
        let results = await testCleaner(home).clean(caches).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")
        for kept in ["Cookies", "Login Data", "IndexedDB", "Local Storage", "Preferences"] {
            #expect(pathExists(home.path(slack + "/" + kept)), "\(kept)")
        }
        // removeContents keeps each cache folder itself.
        #expect(pathExists(home.path(slack + "/Cache")))
    }

    // MARK: llama.cpp

    /// llama.cpp downloads models into ~/Library/Caches/llama.cpp, and
    /// people save their own converted or quantized models there too. Both
    /// are Info: one takes a long download to get back, the other can't be
    /// downloaded at all, and no folder above them can be cleaned.
    @Test func llamaCppModelsAreInfoAndSurviveEveryClean() async throws {
        let home = try TempDir("home")
        let downloaded = try home.write(
            "Library/Caches/llama.cpp/ggml-org_gemma-3-1b-it-GGUF_gemma-3-1b-it-Q4_K_M.gguf", bytes: 300_000)
        try home.write("Library/Caches/llama.cpp/ggml-org_gemma-3-1b-it-GGUF_gemma-3-1b-it-Q4_K_M.gguf.json", text: "{}")
        let local = try home.write("Library/Caches/llama.cpp/my-finetune-Q5_K_M.gguf", bytes: 200_000)
        try home.write("Library/Caches/com.example.other/blob", bytes: 100_000)
        let (report, byPath) = try await scanAll(home)

        let models = try #require(byPath[home.path("Library/Caches/llama.cpp")])
        #expect(models.safety == .info)
        #expect(!models.action.isAutomatic)
        #expect(models.explanation.contains("can't be downloaded"))

        let offered = report.findings.filter(\.action.isAutomatic).map(\.id)
        let everything = offered + ["Library/Caches/llama.cpp", "Library/Caches", "Library"].map(home.path)
        let results = await testCleaner(home).clean(everything).results
        #expect(results.filter(\.ok).map(\.id) == offered)
        #expect(pathExists(downloaded))
        #expect(pathExists(local))
    }

    // MARK: renv

    /// renv installs each package once into its cache and links it into
    /// every project's library. Cleaning everything Midden offers, Safe
    /// and Review alike, must leave a renv project's packages loadable.
    @Test func renvProjectsKeepTheirPackagesWhenEverythingElseIsCleaned() async throws {
        let home = try TempDir("home")
        let cached = OwnershipTests.renv + "/cache/v5/R-4.4/aarch64-apple-darwin20/jsonlite/1.8.8/0a1b2c3d/jsonlite"
        try home.write(cached + "/DESCRIPTION", text: "Package: jsonlite\nVersion: 1.8.8\n")
        try home.write(cached + "/R/jsonlite.rdb", bytes: 200_000)
        try home.write("Library/Caches/org.R-project.R/R/pak/metadata.rds", bytes: 200_000)
        try home.write("Library/Caches/com.example.other/blob", bytes: 200_000)
        try home.write("Library/Caches/Yarn/v6/blob", bytes: 200_000)
        let library = try home.mkdir("code/analysis/renv/library/R-4.4/aarch64-apple-darwin20")
        try home.write("code/analysis/renv.lock", text: "{}")
        try FileManager.default.createSymbolicLink(atPath: library + "/jsonlite", withDestinationPath: home.path(cached))

        let (report, byPath) = try await scanAll(home)
        #expect(byPath[home.path(OwnershipTests.renv)]?.safety == .info)
        let offered = report.findings.filter { $0.action.isAutomatic && $0.category != .largeFiles }.map(\.id)
        #expect(offered.contains(home.path("Library/Caches/Yarn")))
        #expect(offered.contains(home.path("Library/Caches/com.example.other")))
        let results = await testCleaner(home).clean(offered).results
        #expect(results.allSatisfy { $0.ok }, "\(results)")

        // The project's link still leads to the package.
        let description = try String(contentsOfFile: library + "/jsonlite/DESCRIPTION", encoding: .utf8)
        #expect(description.contains("Package: jsonlite"))
        #expect(!pathExists(home.path("Library/Caches/Yarn")))
    }

    // MARK: Poetry

    static let poetry = "Library/Caches/pypoetry"
    static let environment = poetry + "/virtualenvs/app-Xa1b2c3-py3.12"
    static let handmade = environment + "/lib/python3.12/site-packages/handmade/__init__.py"

    /// Poetry keeps every project's virtual environment in its cache
    /// folder. One can hold a package installed by hand or a file edited
    /// in place, which no lock file records, so environments are Review
    /// and never go with their parent.
    @Test func poetryEnvironmentsAreReviewAndSurviveTheirParent() async throws {
        let home = try TempDir("home")
        try home.write(Self.environment + "/pyvenv.cfg", text: "home = /usr/bin\nversion = 3.12.4\n")
        try home.write(Self.handmade, bytes: 50_000)
        try home.write(Self.poetry + "/cache/repositories/PyPI/_http/a/b/c", bytes: 200_000)
        try home.write(Self.poetry + "/artifacts/ab/cd/requests-2.32.3-py3-none-any.whl", bytes: 300_000)
        try home.write(Self.poetry + "/unknown/data", bytes: 10_000)
        let (_, byPath) = try await scanAll(home)

        let environments = try #require(byPath[home.path(Self.poetry + "/virtualenvs")])
        #expect(environments.safety == .review)
        #expect(environments.explanation.contains("by hand"))
        for safe in ["cache", "artifacts"] {
            let finding = try #require(byPath[home.path(Self.poetry + "/" + safe)], "\(safe)")
            #expect(finding.safety == .safe, "\(safe)")
        }
        let parent = try #require(byPath[home.path(Self.poetry)])
        #expect(parent.safety == .info)
        #expect(!parent.action.isAutomatic)
        // The environment isn't also a build folder of its own.
        #expect(byPath[home.path(Self.environment)] == nil)

        // The wildcard above can't take the environments with it.
        let above = [Self.poetry, "Library/Caches", Self.environment]
        for result in await testCleaner(home).clean(above.map(home.path)).results {
            #expect(!result.ok, "\(result.id)")
        }
        // Cleaning the Safe parts beside them leaves them alone.
        let safe = await testCleaner(home).clean([home.path(Self.poetry + "/cache"), home.path(Self.poetry + "/artifacts")])
        #expect(safe.results.allSatisfy { $0.ok }, "\(safe.results)")
        #expect(pathExists(home.path(Self.handmade)))
        #expect(!pathExists(home.path(Self.poetry + "/cache")))
    }
}
