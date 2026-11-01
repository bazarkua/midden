import Foundation

/// A known location in the home folder and what Midden says about it.
struct Rule: Sendable {
    enum AppSource: Sendable {
        case none
        case fixed(AppHint)
        /// The app is named by the folder the `*` matched.
        case wildcard
    }

    /// Paths relative to the home folder. A `*` component matches any one
    /// folder name except Apple's own (see `RuleCatalog.isAppleOwned`).
    var paths: [String]
    var category: Category
    var safety: Safety
    /// `{name}` is the folder's name, `{app}` the app the `*` matched.
    var title: String
    var group: String
    var explanation: String
    var action: CleanAction
    var app: AppSource = .none
    /// Whether nothing inside is reported on its own.
    var claimsSubtree = true
}

struct RuleMatch: Sendable {
    var rule: Rule
    /// The folder name the `*` matched, if the rule has one.
    var wildcard: String?
    /// Other rules match folders inside this one (renv's cache inside R's
    /// cache folder). The scanner keeps classifying inside it, its finding
    /// is only what no other finding covers, and Midden never removes it as
    /// a whole, so nothing protected inside can go with it.
    var isContainer = false
}

enum RuleCatalog {
    /// Most specific first: the first matching rule wins.
    static let rules: [Rule] = [
        // MARK: Developer tools
        Rule(
            paths: ["Library/Developer/Xcode/DerivedData"],
            category: .developerTools, safety: .safe,
            title: "Xcode DerivedData", group: "Xcode",
            explanation: """
                Build products, intermediate files and indexes Xcode keeps for each project it \
                builds. Xcode recreates them as needed; the next build of each project starts \
                from scratch and takes longer, and Xcode indexes the project again.
                """,
            action: .removeContents,
            app: .fixed(AppHint(name: "Xcode", bundleID: "com.apple.dt.Xcode"))),
        Rule(
            paths: [
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Library/Developer/Xcode/watchOS DeviceSupport",
                "Library/Developer/Xcode/tvOS DeviceSupport",
                "Library/Developer/Xcode/visionOS DeviceSupport",
            ],
            category: .developerTools, safety: .safe,
            title: "{name}", group: "Xcode",
            explanation: """
                Debug symbols Xcode copied from devices you connected for debugging, one folder \
                per OS version. Xcode copies them again the next time you debug on a device with \
                that OS version, which takes a while.
                """,
            action: .removeContents,
            app: .fixed(AppHint(name: "Xcode", bundleID: "com.apple.dt.Xcode"))),
        Rule(
            paths: ["Library/Developer/Xcode/Archives"],
            category: .developerTools, safety: .review,
            title: "Xcode archives", group: "Xcode",
            explanation: """
                Builds you made with Product → Archive. Each archive keeps the debug symbols \
                needed to symbolicate crash reports from that build. Keep the archives of \
                versions people still use; without them their crash reports stay unreadable.
                """,
            action: .removeContents,
            app: .fixed(AppHint(name: "Xcode", bundleID: "com.apple.dt.Xcode"))),
        Rule(
            paths: ["Library/Developer/Xcode/UserData/Previews"],
            category: .developerTools, safety: .safe,
            title: "SwiftUI previews", group: "Xcode",
            explanation: """
                Data Xcode builds to show SwiftUI previews. Xcode recreates it the next time \
                you open a preview.
                """,
            action: .removeContents,
            app: .fixed(AppHint(name: "Xcode", bundleID: "com.apple.dt.Xcode"))),
        Rule(
            paths: ["Library/Developer/CoreSimulator/Caches"],
            category: .developerTools, safety: .safe,
            title: "Simulator caches", group: "Simulator",
            explanation: """
                Caches the Simulator creates for its runtimes. It recreates them when needed, \
                so the next simulator launch can be slower.
                """,
            action: .removeContents,
            app: .fixed(AppHint(name: "Simulator", bundleID: "com.apple.iphonesimulator"))),
        Rule(
            paths: ["Library/Developer/CoreSimulator/Devices"],
            category: .developerTools, safety: .info,
            title: "Simulators", group: "Simulator",
            explanation: """
                Your simulators, with the apps and data installed in them. Midden lists \
                simulators whose runtime is no longer installed separately; delete the others \
                only if you don't need them.
                """,
            action: .manual("""
                Delete simulators in Xcode → Window → Devices and Simulators, or remove the \
                ones Xcode can no longer run with `xcrun simctl delete unavailable`.
                """)),
        Rule(
            paths: ["Library/Android/sdk/system-images"],
            category: .developerTools, safety: .info,
            title: "Android system images", group: "Android",
            explanation: """
                System images for Android emulators, downloaded by Android Studio. Each \
                emulator needs the image it was created with.
                """,
            action: .manual("Remove the images you don't use in Android Studio → Settings → Android SDK.")),
        Rule(
            paths: [".android/avd"],
            category: .developerTools, safety: .info,
            title: "Android virtual devices", group: "Android",
            explanation: """
                The Android emulators you created, with their disks and snapshots.
                """,
            action: .manual("Delete the devices you don't need in Android Studio → Device Manager.")),
        Rule(
            paths: ["Library/Containers/com.docker.docker"],
            category: .developerTools, safety: .info,
            title: "Docker Desktop data", group: "Docker",
            explanation: """
                Docker Desktop's virtual disk, which holds your images, containers and volumes. \
                Midden counts the space it takes on disk, which can be far less than the disk \
                size Docker shows.
                """,
            action: .manual("""
                Run `docker system prune` to remove stopped containers, unused networks, \
                dangling images and build cache, or lower the disk limit in Docker Desktop → \
                Settings → Resources.
                """),
            app: .fixed(AppHint(name: "Docker Desktop", bundleID: "com.docker.docker"))),

        // MARK: AI coding tools
        // What each folder holds was checked on a real Mac from folder and
        // file names only. Conversation history is the user's own data; the
        // tools' programs, VMs and extensions are theirs to manage. None of
        // these are deleted by Midden. Worktrees these tools create are found
        // and audited one by one, so no rule covers ~/.codex/worktrees or
        // ~/.cursor/worktrees.
        Rule(
            paths: [".claude/projects"],
            category: .personal, safety: .info,
            title: "Claude Code conversations", group: "Claude Code",
            explanation: """
                Your Claude Code conversation history: one transcript per session, in a folder \
                per project. `claude --resume` and `claude --continue` read it. Claude Code \
                deletes sessions older than its `cleanupPeriodDays` setting (30 days by default).
                """,
            action: .manual("To keep less history, lower `cleanupPeriodDays` in ~/.claude/settings.json.")),
        Rule(
            paths: [".claude/plugins"],
            category: .developerTools, safety: .info,
            title: "Claude Code plugins", group: "Claude Code",
            explanation: """
                Plugins you installed in Claude Code, and copies of the plugin marketplaces \
                they come from.
                """,
            action: .manual("Manage plugins and marketplaces with `/plugin` in Claude Code.")),
        Rule(
            paths: [".local/share/claude/versions"],
            category: .developerTools, safety: .info,
            title: "Claude Code versions", group: "Claude Code",
            explanation: """
                Versions of Claude Code installed by its native installer, one folder per \
                version. The `claude` command (~/.local/bin/claude) runs one of them.
                """,
            action: .manual("Claude Code installs and updates these itself; Midden leaves them alone.")),
        Rule(
            paths: ["Library/Application Support/Claude/vm_bundles"],
            category: .developerTools, safety: .info,
            title: "Claude app virtual machine", group: "Claude",
            explanation: """
                A Linux virtual machine the Claude app downloaded to run tasks in isolation (it's \
                marked as used by Cowork). It holds the machine's system disk (rootfs.img), the \
                compressed download it was unpacked from (rootfs.img.zst) and a disk for \
                session data (sessiondata.img).
                """,
            action: .manual("""
                The Claude app manages this folder. Midden doesn't delete it because the session \
                disk can hold files from your sessions.
                """),
            app: .fixed(AppHint(name: "Claude", bundleID: "com.anthropic.claudefordesktop"))),
        Rule(
            paths: ["Library/Application Support/Claude/claude-code"],
            category: .developerTools, safety: .info,
            title: "Claude Code in the Claude app", group: "Claude",
            explanation: "Copies of Claude Code the Claude app downloaded, one folder per version.",
            action: .manual("The Claude app manages these; Midden leaves them alone."),
            app: .fixed(AppHint(name: "Claude", bundleID: "com.anthropic.claudefordesktop"))),
        Rule(
            paths: ["Library/Application Support/Claude/claude-code-vm"],
            category: .developerTools, safety: .info,
            title: "Claude Code for the Claude app's VM", group: "Claude",
            explanation: """
                A build of Claude Code the Claude app keeps for its virtual machine, one folder \
                per version.
                """,
            action: .manual("The Claude app manages these; Midden leaves them alone."),
            app: .fixed(AppHint(name: "Claude", bundleID: "com.anthropic.claudefordesktop"))),
        Rule(
            paths: [".codex/sessions"],
            category: .personal, safety: .info,
            title: "Codex conversations", group: "Codex",
            explanation: """
                Your Codex conversation history: one transcript per session, in folders by date. \
                `codex resume` reads it.
                """,
            action: .manual("Midden leaves your Codex history alone.")),
        Rule(
            paths: [".codex/generated_images"],
            category: .personal, safety: .info,
            title: "Images generated in Codex", group: "Codex",
            explanation: "Images Codex generated during your sessions, grouped in folders.",
            action: .manual("Keep the images you want, then delete the rest in Finder.")),
        Rule(
            paths: [".codex/packages"],
            category: .developerTools, safety: .info,
            title: "Codex packages", group: "Codex",
            explanation: """
                Programs Codex downloads and keeps up to date itself, such as its app-server \
                daemon, one folder per version.
                """,
            action: .manual("Codex manages these; Midden leaves them alone.")),
        Rule(
            paths: [".codex/plugins"],
            category: .developerTools, safety: .info,
            title: "Codex plugins", group: "Codex",
            explanation: """
                Plugins Codex downloaded from OpenAI's plugin catalogs, such as openai-curated \
                and openai-bundled.
                """,
            action: .manual("Codex manages these; Midden leaves them alone.")),
        Rule(
            paths: ["Library/Application Support/Codex/artifact-sessions"],
            category: .developerTools, safety: .info,
            title: "Codex app runtime", group: "Codex",
            explanation: """
                A runtime the Codex app installed for artifact sessions: programs \
                (runtime/bin) and Node packages (runtime/node_modules).
                """,
            action: .manual("The Codex app manages this; Midden leaves it alone."),
            app: .fixed(AppHint(name: "Codex", bundleID: "com.openai.codex"))),
        Rule(
            paths: [".cursor/extensions"],
            category: .developerTools, safety: .info,
            title: "Cursor extensions", group: "Cursor",
            explanation: "Extensions you installed in Cursor, one folder per extension version.",
            action: .manual("Uninstall the ones you don't use from Cursor's Extensions view."),
            app: .fixed(AppHint(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"))),
        Rule(
            paths: [".cursor/chats"],
            category: .personal, safety: .info,
            title: "Cursor agent chats", group: "Cursor",
            explanation: "Conversations with Cursor's agent, one small database per chat.",
            action: .manual("Midden leaves your chat history alone.")),
        Rule(
            paths: [".local/share/cursor-agent/versions"],
            category: .developerTools, safety: .info,
            title: "Cursor CLI versions", group: "Cursor",
            explanation: """
                Versions of Cursor's command-line agent, one folder per version. The \
                `cursor-agent` command (~/.local/bin/cursor-agent) runs one of them.
                """,
            action: .manual("cursor-agent installs and updates these itself; Midden leaves them alone.")),
        Rule(
            paths: ["Library/Application Support/Cursor/snapshots"],
            category: .developerTools, safety: .info,
            title: "Cursor snapshots", group: "Cursor",
            explanation: """
                Snapshots of your projects that Cursor stores: a folder per project in roots/, \
                with the data in stores/ and codebases/. Midden can't tell which of them Cursor \
                still needs.
                """,
            action: .manual("Midden leaves this folder to Cursor."),
            app: .fixed(AppHint(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"))),
        Rule(
            paths: [".gemini/antigravity"],
            category: .personal, safety: .info,
            title: "Antigravity conversations", group: "Antigravity",
            explanation: """
                Your Antigravity conversations, the plans and task lists its agents wrote for \
                each one (in brain/), and browser recordings.
                """,
            action: .manual("Midden leaves your Antigravity history alone.")),
        Rule(
            paths: [".gemini/antigravity-browser-profile"],
            category: .developerTools, safety: .info,
            title: "Antigravity browser profile", group: "Antigravity",
            explanation: """
                The Chrome profile Antigravity's browser agent uses, with its cache, cookies, \
                history and sign-ins. Deleting it would sign that browser out of every site.
                """,
            action: .manual("Midden leaves this profile to Antigravity.")),
        Rule(
            paths: [".antigravity/extensions"],
            category: .developerTools, safety: .info,
            title: "Antigravity extensions", group: "Antigravity",
            explanation: "Extensions you installed in Antigravity, one folder per extension version.",
            action: .manual("Uninstall the ones you don't use from Antigravity's Extensions view."),
            app: .fixed(AppHint(name: "Antigravity", bundleID: "com.google.antigravity"))),
        Rule(
            paths: [".gemini/tmp"],
            category: .developerTools, safety: .info,
            title: "Gemini CLI project files", group: "Gemini CLI",
            explanation: """
                Files Gemini CLI keeps for each project you used it in, one folder per project, \
                named by a hash.
                """,
            action: .manual("Midden leaves these to Gemini CLI.")),
        Rule(
            paths: [".grok/downloads"],
            category: .developerTools, safety: .info,
            title: "Grok CLI downloads", group: "Grok CLI",
            explanation: """
                Builds of Grok CLI it downloaded, one folder per build. The `grok` command \
                (~/.grok/bin/grok) runs one of them.
                """,
            action: .manual("Grok CLI manages these; Midden leaves them alone.")),
        Rule(
            paths: [".copilot/session-state"],
            category: .personal, safety: .info,
            title: "GitHub Copilot CLI sessions", group: "GitHub Copilot",
            explanation: "Session state GitHub Copilot CLI saves, one folder per session.",
            action: .manual("Midden leaves these to Copilot CLI.")),
        Rule(
            paths: [".vscode/extensions"],
            category: .developerTools, safety: .info,
            title: "VS Code extensions", group: "VS Code",
            explanation: "Extensions you installed in Visual Studio Code, one folder per extension version.",
            action: .manual("Uninstall the ones you don't use from VS Code's Extensions view."),
            app: .fixed(AppHint(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"))),

        // MARK: Package caches
        Rule(
            paths: [".npm/_cacache"],
            category: .packageCaches, safety: .safe,
            title: "npm cache", group: "npm",
            explanation: """
                Packages npm downloaded. npm downloads them again when a project needs them.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".gradle/caches"],
            category: .packageCaches, safety: .safe,
            title: "Gradle caches", group: "Gradle",
            explanation: """
                Dependencies Gradle downloaded and outputs it cached between builds. Gradle \
                downloads and rebuilds them on the next build, which takes longer. Stop running \
                Gradle daemons first with `./gradlew --stop`.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".gradle/wrapper/dists"],
            category: .packageCaches, safety: .review,
            title: "Gradle distributions", group: "Gradle",
            explanation: """
                Versions of Gradle downloaded by projects' Gradle wrapper (gradlew). Each \
                project downloads its Gradle version again on its next build.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cargo/registry"],
            category: .packageCaches, safety: .safe,
            title: "Cargo registry", group: "Cargo",
            explanation: """
                The crates.io index and the crates Cargo downloaded and unpacked. Cargo \
                downloads them again on the next build.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cocoapods/repos"],
            category: .packageCaches, safety: .safe,
            title: "CocoaPods spec repos", group: "CocoaPods",
            explanation: """
                Local copies of CocoaPods spec repositories. `pod install` fetches specs again \
                as needed, and clones a spec repo again when a Podfile names it as a source.
                """,
            action: .removeContents),
        Rule(
            paths: [".m2/repository"],
            category: .packageCaches, safety: .review,
            title: "Maven repository", group: "Maven",
            explanation: """
                Libraries Maven downloaded. Maven downloads them again on the next build. \
                Libraries you installed locally with `mvn install` are lost too and must be \
                built again.
                """,
            action: .removeDirectory),
        Rule(
            paths: ["Library/pnpm/store"],
            category: .packageCaches, safety: .info,
            title: "pnpm store", group: "pnpm",
            explanation: """
                pnpm keeps one copy of every package here and hard-links its files into your \
                projects' node_modules, so deleting the store frees little while those \
                projects exist.
                """,
            action: .manual("Run `pnpm store prune` to remove packages no project uses.")),
        Rule(
            paths: [".cache/uv"],
            category: .packageCaches, safety: .safe,
            title: "uv cache", group: "uv",
            explanation: """
                Python packages uv downloaded and built. uv downloads them again as needed. \
                Your virtual environments keep working, but deleting the cache can free less \
                than shown, because uv links these files into them.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cache/pip", "Library/Caches/pip"],
            category: .packageCaches, safety: .safe,
            title: "pip cache", group: "pip",
            explanation: """
                Python packages pip downloaded and wheels it built. pip downloads them again \
                when needed.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cache/huggingface"],
            category: .packageCaches, safety: .info,
            title: "Hugging Face models", group: "Hugging Face",
            explanation: """
                Models and datasets downloaded by Hugging Face libraries. Large models can take \
                a long time to download again.
                """,
            action: .manual("Remove the models you no longer use with `huggingface-cli delete-cache`.")),
        Rule(
            paths: [".cache/torch"],
            category: .packageCaches, safety: .review,
            title: "PyTorch downloads", group: "PyTorch",
            explanation: """
                Model weights and code PyTorch downloaded. They're downloaded again the next \
                time a program loads them.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cache/puppeteer"],
            category: .packageCaches, safety: .review,
            title: "Puppeteer browsers", group: "Puppeteer",
            explanation: """
                Browsers Puppeteer downloaded. Run `npx puppeteer browsers install chrome` if \
                a project needs them again.
                """,
            action: .removeDirectory),
        Rule(
            paths: [".cache/*"],
            category: .packageCaches, safety: .review,
            title: "~/.cache/{name}", group: "{name}",
            explanation: """
                Data a command-line tool stored in ~/.cache, the standard place for files a \
                program can recreate. Check which tool it belongs to before deleting it.
                """,
            action: .removeDirectory),

        // MARK: App caches
        Rule(
            paths: ["Library/Caches/ms-playwright"],
            category: .appCaches, safety: .review,
            title: "Playwright browsers", group: "Playwright",
            explanation: """
                Browsers Playwright downloaded to run tests. Run `npx playwright install` \
                before your next test run.
                """,
            action: .removeDirectory),
        Rule(
            paths: ["Library/Caches/Homebrew"],
            category: .appCaches, safety: .safe,
            title: "Homebrew downloads", group: "Homebrew",
            explanation: """
                Packages Homebrew downloaded and kept after installing them. Deleting them is \
                similar to `brew cleanup -s`; Homebrew downloads them again if it needs them.
                """,
            action: .removeContents),
        // R packages keep their caches in R_user_dir("<package>", "cache"),
        // here on macOS. renv's is a package library that every renv
        // project links into, so it's never removed with its parent.
        Rule(
            paths: ["Library/Caches/org.R-project.R"],
            category: .appCaches, safety: .info,
            title: "R package caches", group: "R",
            explanation: """
                Caches that R packages keep. renv's package cache, which your R projects use, \
                is listed separately and kept, so Midden never deletes this folder as a whole.
                """,
            action: .manual("Clear a package's cache with that package's own functions, such as `renv::clean()` for renv.")),
        Rule(
            paths: ["Library/Caches/org.R-project.R/R/renv"],
            category: .packageCaches, safety: .info,
            title: "renv package cache", group: "R",
            explanation: """
                The packages renv installed for your R projects, kept once and linked into each \
                project's library. Deleting it breaks every project that links to it until you \
                reinstall their packages.
                """,
            action: .manual("Remove packages no project uses with `renv::clean()` in a project, or `renv::purge()`.")),
        Rule(
            paths: ["Library/Caches/*"],
            category: .appCaches, safety: .safe,
            title: "{app} cache", group: "{app}",
            explanation: """
                Files {app} keeps to load faster. Apps recreate them as needed, so {app} may be \
                slower the first time. Quit {app} first.
                """,
            action: .removeDirectory,
            app: .wildcard),
        Rule(
            paths: [
                "Library/Application Support/*/Cache",
                "Library/Application Support/*/Code Cache",
                "Library/Application Support/*/GPUCache",
                "Library/Application Support/*/CachedData",
            ],
            category: .appCaches, safety: .safe,
            title: "{app} web cache ({name})", group: "{app}",
            explanation: """
                Web cache of {app}. Apps built on Electron or Chromium, such as Slack, VS Code, \
                Cursor or Discord, keep it to load faster and rebuild it as needed. Quit {app} \
                first.
                """,
            action: .removeContents,
            app: .wildcard),

        // MARK: Logs and Trash
        Rule(
            paths: ["Library/Logs"],
            category: .system, safety: .safe,
            title: "Logs", group: "Logs",
            explanation: """
                Log files and crash reports written by apps. Apps start new logs as they run; \
                you only lose the history, which matters when you're diagnosing a problem.
                """,
            action: .removeContents),
        Rule(
            paths: [".Trash"],
            category: .system, safety: .review,
            title: "Trash", group: "Trash",
            explanation: """
                Files you moved to the Trash. Emptying it deletes them for good: you can't get \
                these files back afterward.
                """,
            action: .removeContents),
        Rule(
            paths: ["Library/Application Support/MobileSync/Backup"],
            category: .system, safety: .info,
            title: "iPhone and iPad backups", group: "Device backups",
            explanation: """
                Backups of your iPhone or iPad made on this Mac. A backup may be the only copy \
                of data that isn't in iCloud.
                """,
            action: .manual("Delete old backups in Finder: select the device, then Manage Backups.")),

        // MARK: Your files
        Rule(
            paths: ["Downloads"],
            category: .personal, safety: .info,
            title: "Downloads", group: "Downloads",
            explanation: """
                Files you downloaded. Midden doesn't delete your files, but lists large \
                installers in here separately.
                """,
            action: .manual("Sort the folder by size in Finder to find the big files you no longer need."),
            claimsSubtree: false),
        Rule(
            paths: [".ollama/models"],
            category: .personal, safety: .info,
            title: "Ollama models", group: "Ollama",
            explanation: """
                Language models downloaded by Ollama. Large models take a long time to download \
                again.
                """,
            action: .manual("See your models with `ollama list` and remove the ones you don't use with `ollama rm <model>`.")),
    ]

    private struct Pattern: Sendable {
        var components: [String]
        var rule: Rule
    }

    private static let patterns: [Pattern] = rules.flatMap { rule in
        rule.paths.map { Pattern(components: $0.split(separator: "/").map(String.init), rule: rule) }
    }

    /// Directories deeper than this, relative to home, can't match a rule.
    static let maxDepth = patterns.map(\.components.count).max() ?? 0

    /// Whether any rule matches a folder strictly inside `relative`, so a
    /// folder there must stay a container.
    static func hasNestedRules(below relative: [String]) -> Bool {
        guard !relative.isEmpty, relative.count < maxDepth else { return false }
        return patterns.contains { pattern in
            pattern.components.count > relative.count
                && zip(pattern.components, relative).allSatisfy { expected, actual in
                    expected == "*" ? !isAppleOwned(actual) : expected == actual
                }
        }
    }

    /// The first rule matching a directory, given its path components
    /// relative to the home folder.
    static func match(_ relative: [String]) -> RuleMatch? {
        guard !relative.isEmpty, relative.count <= maxDepth else { return nil }
        patterns: for pattern in patterns where pattern.components.count == relative.count {
            var wildcard: String?
            for (expected, actual) in zip(pattern.components, relative) {
                if expected == "*" {
                    if isAppleOwned(actual) { continue patterns }
                    wildcard = actual
                } else if expected != actual {
                    continue patterns
                }
            }
            return RuleMatch(rule: pattern.rule, wildcard: wildcard)
        }
        return nil
    }

    /// Folders macOS itself keeps in ~/Library/Caches and Application
    /// Support. Midden leaves them to the system.
    static func isAppleOwned(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || appleFolders.contains(name)
    }

    private static let appleFolders: Set<String> = [
        "Animoji", "askpermissiond", "CloudKit", "ColorSync", "FamilyCircle", "familycircled",
        "GameKit", "GeoServices", "icloudmailagent", "PassKit",
    ]
}
