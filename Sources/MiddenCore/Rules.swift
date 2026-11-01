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
            title: "{app} {name}", group: "{app}",
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
