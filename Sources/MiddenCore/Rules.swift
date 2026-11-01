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
    /// For `removeContents`: which contents go, when not all of them may.
    /// Engine-internal: the cleaner takes it from the rule it matches again
    /// at clean time.
    var contents: ContentsPolicy? = nil
    /// Whether a running program can depend on it: run from it, work in
    /// it, or name it in its arguments. Checked against the user's
    /// processes after the scan and again when cleaning; while a program
    /// uses it, or the processes can't all be read, it's Info.
    var checkInUse = false
    /// What the folder itself must show for the rule to apply; when it
    /// doesn't, the next matching rule does.
    var requires: Requirement? = nil

    enum Requirement: Sendable {
        /// A Chromium profile folder: a `Local State` file, or the `mcp-`
        /// prefix Playwright MCP gives its profiles.
        case browserProfile
        /// A download in progress or interrupted: an `.incomplete` file.
        case unfinishedDownload
    }
}

extension Rule.Requirement {
    func isMet(by folder: DirectoryFacts) -> Bool { RuleCatalog.isMet(self, by: folder) }
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
            category: .appCaches, safety: .review,
            title: "Browser profile ({name})", group: "{name}",
            explanation: """
                A Chromium browser profile (it has a Local State file) kept in ~/.cache, \
                usually by a tool that drives a browser. Midden doesn't know its owner. \
                Deleting it signs that browser out of every site and loses its cookies, \
                history and saved site data. Quit the browser, and any agent or tool that \
                drives it, first.
                """,
            action: .removeDirectory,
            checkInUse: true,
            requires: .browserProfile),
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
        // Playwright downloads browsers into ~/Library/Caches/ms-playwright.
        // Playwright MCP keeps persistent, signed-in profiles there too, as
        // mcp-<channel>-<workspace hash> (its README's "User profile"), or
        // in ms-playwright-mcp (seen on a Mac). Profiles aren't caches.
        Rule(
            paths: ["Library/Caches/ms-playwright"],
            category: .appCaches, safety: .info,
            title: "Playwright", group: "Playwright",
            explanation: """
                Playwright's folder: the browsers it downloaded to run tests and, if you use \
                Playwright MCP, the browser profiles it keeps signed in. Each is listed \
                separately, so Midden never deletes this folder as a whole.
                """,
            action: .manual("Clean the browsers and profiles listed separately.")),
        Rule(
            paths: ["Library/Caches/ms-playwright/*", "Library/Caches/ms-playwright-mcp"],
            category: .appCaches, safety: .review,
            title: "Playwright MCP browser profile ({name})", group: "Playwright",
            explanation: """
                A browser profile Playwright MCP keeps so its browser stays signed in between \
                sessions, with cookies, saved logins and site data. It isn't a browser download. \
                Deleting it signs that browser out of every site and loses its cookies, \
                history and saved site data. Quit the browser, and any agent or tool that \
                drives it, first.
                """,
            action: .removeDirectory,
            checkInUse: true,
            requires: .browserProfile),
        Rule(
            paths: ["Library/Caches/ms-playwright-mcp"],
            category: .appCaches, safety: .review,
            title: "Playwright MCP browser profiles", group: "Playwright",
            explanation: """
                Browser profiles Playwright MCP keeps so its browser stays signed in between \
                sessions, one folder per profile, with cookies, saved logins and site data. \
                They aren't browser downloads. Deleting them signs that browser out of every \
                site and loses its cookies, history and saved site data. Quit the browser, and \
                any agent or tool that drives it, first.
                """,
            action: .removeDirectory,
            checkInUse: true),
        Rule(
            paths: ["Library/Caches/ms-playwright/*"],
            category: .appCaches, safety: .review,
            title: "Playwright browser ({name})", group: "Playwright",
            explanation: """
                A browser Playwright downloaded to run tests. Run `npx playwright install` \
                before your next test run.
                """,
            action: .removeDirectory,
            checkInUse: true),
        // Homebrew's cache (`brew --cache`). Only downloads/ is cleaned:
        // api/ and bootsnap/ make `brew` itself fast (a comment in Mole's
        // cleaner says wiping them slowed its next run). `brew cleanup -s`
        // is not the same thing: it keeps downloads of installed formulae and
        // casks (`brew cleanup --help`).
        Rule(
            paths: ["Library/Caches/Homebrew"],
            category: .appCaches, safety: .info,
            title: "Homebrew cache", group: "Homebrew",
            explanation: """
                Homebrew's cache: the packages it downloaded, listed separately, and data that \
                makes `brew` start faster, which Midden leaves alone. Midden never deletes this \
                folder as a whole.
                """,
            action: .manual("Run `brew cleanup` to let Homebrew remove what it no longer needs.")),
        Rule(
            paths: ["Library/Caches/Homebrew/downloads"],
            category: .appCaches, safety: .review,
            title: "Homebrew downloads", group: "Homebrew",
            explanation: """
                Packages Homebrew downloaded. One download is unfinished: Homebrew is \
                downloading it now, or a download was interrupted. Homebrew downloads a package \
                again if it needs it, for example to reinstall.
                """,
            action: .removeContents,
            checkInUse: true,
            requires: .unfinishedDownload),
        Rule(
            paths: ["Library/Caches/Homebrew/downloads"],
            category: .appCaches, safety: .safe,
            title: "Homebrew downloads", group: "Homebrew",
            explanation: """
                Packages Homebrew downloaded. Homebrew downloads a package again if it needs it, \
                for example to reinstall.
                """,
            action: .removeContents,
            checkInUse: true),
        // llama.cpp downloads models (`-hf`) to LLAMA_CACHE, by default
        // ~/Library/Caches/llama.cpp on macOS (fs_get_cache_directory in
        // common/common.cpp). People save their own models there too.
        Rule(
            paths: ["Library/Caches/llama.cpp"],
            category: .personal, safety: .info,
            title: "llama.cpp models", group: "llama.cpp",
            explanation: """
                Language models llama.cpp downloaded, and any model files saved here by hand. \\
                Large models take a long time to download again, and a model you converted or \\
                quantized yourself can't be downloaded at all.
                """,
            action: .manual("Delete the models you no longer use in Finder.")),
        // pnpm's cacheDir is ~/Library/Caches/pnpm on macOS and holds
        // "package metadata, dlx cache, and some install verification
        // results" (pnpm.io/settings/other). The dlx folders hold the
        // packages of commands run with `pnpm dlx`, which can be running.
        Rule(
            paths: ["Library/Caches/pnpm"],
            category: .packageCaches, safety: .info,
            title: "pnpm cache", group: "pnpm",
            explanation: """
                pnpm's cache folder: package metadata, and the packages of commands you ran \
                with `pnpm dlx`. Each is listed separately, so Midden never deletes this folder \
                as a whole.
                """,
            action: .manual("Clean the parts listed separately.")),
        Rule(
            paths: ["Library/Caches/pnpm/dlx"],
            category: .packageCaches, safety: .review,
            title: "pnpm dlx packages", group: "pnpm",
            explanation: """
                Packages pnpm downloaded to run commands with `pnpm dlx`, one folder per \
                command. pnpm downloads them again the next time you run that command. How long \
                ago a folder changed doesn't show whether a command still uses it, so Midden \
                checks that no running program does.
                """,
            action: .removeDirectory,
            checkInUse: true),
        Rule(
            paths: ["Library/Caches/pnpm/*"],
            category: .packageCaches, safety: .safe,
            title: "pnpm metadata ({name})", group: "pnpm",
            explanation: """
                Package metadata and install checks pnpm cached. pnpm downloads or redoes them \
                as needed.
                """,
            action: .removeDirectory),
        // Poetry's cache-dir is ~/Library/Caches/pypoetry on macOS, and its
        // virtualenvs.path defaults to {cache-dir}/virtualenvs (Poetry's
        // configuration docs). Downloads live in cache/repositories and
        // artifacts (repository_cache_directory and
        // artifacts_cache_directory in poetry/config/config.py).
        Rule(
            paths: ["Library/Caches/pypoetry"],
            category: .packageCaches, safety: .info,
            title: "Poetry", group: "Poetry",
            explanation: """
                Poetry's cache folder: the packages it downloaded and, unless you moved them, \
                the virtual environments of your Poetry projects. Each is listed separately, so \
                Midden never deletes this folder as a whole.
                """,
            action: .manual("Clean the parts listed separately; `poetry cache clear` and `poetry env remove` do the same from Poetry.")),
        Rule(
            paths: ["Library/Caches/pypoetry/cache", "Library/Caches/pypoetry/artifacts"],
            category: .packageCaches, safety: .safe,
            title: "Poetry downloads ({name})", group: "Poetry",
            explanation: """
                Package indexes and packages Poetry downloaded. Poetry downloads them again \
                when a project installs them.
                """,
            action: .removeDirectory),
        Rule(
            paths: ["Library/Caches/pypoetry/virtualenvs"],
            category: .packageCaches, safety: .review,
            title: "Poetry virtual environments", group: "Poetry",
            explanation: """
                The virtual environments Poetry made for your projects, one folder per project. \
                `poetry install` recreates one from its project's lock file, but packages \
                installed into it by hand, and files changed inside it, aren't recorded \
                anywhere and are lost.
                """,
            action: .removeDirectory),
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
        // Owners of ~/Library/Caches folders that earn Safe, each with the
        // reason the owner rebuilds what's there. Every other folder in
        // Caches is Review (the wildcard below): macOS asks apps to keep
        // only recreatable files there, but nothing enforces it.
        //
        // Yarn 1: `getCacheDir` in yarnpkg/yarn's src/util/user-dirs.js
        // returns ~/Library/Caches/Yarn on macOS; `yarn cache clean` empties
        // it and installs fill it again.
        Rule(
            paths: ["Library/Caches/Yarn"],
            category: .packageCaches, safety: .safe,
            title: "Yarn cache", group: "Yarn",
            explanation: """
                Packages Yarn 1 downloaded. Yarn downloads them again when a project installs \
                them; `yarn cache clean` deletes the same files.
                """,
            action: .removeDirectory),
        // Go: `go help cache` puts the build cache in go-build inside the
        // user cache directory (~/Library/Caches on macOS); "go clean -cache
        // deletes all cached data".
        Rule(
            paths: ["Library/Caches/go-build"],
            category: .packageCaches, safety: .safe,
            title: "Go build cache", group: "Go",
            explanation: """
                Go's build and test cache. Go rebuilds what it needs, so the next builds and \
                tests take longer; `go clean -cache` deletes the same files.
                """,
            action: .removeDirectory),
        // CocoaPods: cache_root defaults to ~/Library/Caches/CocoaPods
        // (lib/cocoapods/config.rb); `pod cache clean --all` empties it.
        Rule(
            paths: ["Library/Caches/CocoaPods"],
            category: .packageCaches, safety: .safe,
            title: "CocoaPods cache", group: "CocoaPods",
            explanation: """
                Pods and specs CocoaPods downloaded. `pod install` downloads them again when a \
                project needs them; `pod cache clean --all` deletes the same files.
                """,
            action: .removeDirectory),
        // Chromium browsers: GetUserCacheDirectory (chrome_paths_mac.mm)
        // puts a profile's disk cache under ~/Library/Caches at the path
        // its profile has under Application Support, apart from cookies,
        // history and sign-ins, which stay in the profile.
        browserCache("Library/Caches/Google/Chrome", AppHint(name: "Google Chrome", bundleID: "com.google.Chrome")),
        browserCache("Library/Caches/BraveSoftware/Brave-Browser", AppHint(name: "Brave", bundleID: "com.brave.Browser")),
        browserCache("Library/Caches/Microsoft Edge", AppHint(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac")),
        browserCache("Library/Caches/Vivaldi", AppHint(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi")),
        browserCache("Library/Caches/Arc/User Data", AppHint(name: "Arc", bundleID: "company.thebrowser.Browser")),
        browserCache("Library/Caches/Dia/User Data", AppHint(name: "Dia")),
        // A browser profile elsewhere in Caches, e.g. one an agent was
        // started with through --user-data-dir.
        Rule(
            paths: ["Library/Caches/*"],
            category: .appCaches, safety: .review,
            title: "Browser profile ({name})", group: "{app}",
            explanation: """
                A Chromium browser profile (it has a Local State file) kept in your Caches \
                folder, by {app} or by a tool that drives a browser. Midden doesn't know its \
                owner. Deleting it signs that browser out of every site and loses its cookies, \
                history and saved site data. Quit the browser, and any agent or tool that \
                drives it, first.
                """,
            action: .removeDirectory,
            app: .wildcard,
            checkInUse: true,
            requires: .browserProfile),
        Rule(
            paths: ["Library/Caches/*"],
            category: .appCaches, safety: .review,
            title: "{app} cache", group: "{app}",
            explanation: """
                Data {app} keeps in your Caches folder. Midden doesn't know this folder's owner \
                well enough to say it rebuilds everything here: being in Caches doesn't prove \
                that, and some tools keep environments, models or sign-ins in it. Check what it \
                is before deleting it, and quit {app} first.
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
        // Files only, never folders: macOS doesn't recreate some of them.
        // After another cleaner removed DiagnosticReports (owned by the
        // _analyticsusers group), crash reports couldn't be saved:
        // osanalyticshelper was denied creating the folder again.
        Rule(
            paths: ["Library/Logs"],
            category: .system, safety: .safe,
            title: "Logs", group: "Logs",
            explanation: """
                Log files and crash reports apps wrote more than 7 days ago. Midden deletes only \
                those files and keeps every folder, because macOS doesn't recreate some of them, \
                such as DiagnosticReports for crash reports. Newer files stay, so a recent crash \
                report is still there to send; you lose only older history.
                """,
            action: .removeContents,
            contents: .agedFiles(minimumAge: 7 * 86_400)),
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
                installers and build folders in here separately, and leaves them out of this \
                size.
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

    /// A Chromium browser's disk cache, kept per profile apart from the
    /// profile itself.
    private static func browserCache(_ path: String, _ app: AppHint) -> Rule {
        Rule(
            paths: [path],
            category: .appCaches, safety: .safe,
            title: "{app} disk cache", group: "{app}",
            explanation: """
                Copies of pages, images and scripts {app} downloaded, kept per profile. \
                Chromium-based browsers keep this cache apart from your sign-ins, history and \
                settings, and fill it again as you browse. Quit {app} first.
                """,
            action: .removeDirectory,
            app: .fixed(app))
    }

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
    /// - Parameter folder: the folder's own facts, for rules that require
    ///   something of it. Without them those rules don't apply.
    static func match(_ relative: [String], folder: DirectoryFacts? = nil) -> RuleMatch? {
        guard !relative.isEmpty, relative.count <= maxDepth else { return nil }
        patterns: for pattern in patterns where pattern.components.count == relative.count {
            if let requirement = pattern.rule.requires {
                guard let folder, requirement.isMet(by: folder) else { continue patterns }
            }
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

    /// Whether the folder shows what a rule requires of it.
    static func isMet(_ requirement: Rule.Requirement, by folder: DirectoryFacts) -> Bool {
        switch requirement {
        case .browserProfile:
            folder.name.hasPrefix("mcp-")
                || folder.entries.contains { $0.name == "Local State" && $0.kind == .file }
        case .unfinishedDownload:
            folder.entries.contains { $0.name.hasSuffix(".incomplete") }
        }
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
