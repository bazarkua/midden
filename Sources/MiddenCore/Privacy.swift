import Foundation

/// Folders macOS guards with privacy permissions. Without Full Disk Access,
/// listing them fails, or open() waits on a permission prompt. When the Full
/// Disk Access probe fails, the scan skips them up front and counts them as
/// unreadable, instead of finding out one blocked call at a time (the
/// walker's watchdog still catches anything this list misses).
///
/// Two kinds: folders macOS refuses silently (every folder `du` couldn't
/// read on a Mac without Full Disk Access, macOS 27), and folders macOS asks
/// about with a prompt. A scan that opened the second kind would pop up one
/// permission dialog per folder, so without Full Disk Access it leaves them
/// alone and says so instead.
enum PrivacyProtected {
    /// Folders macOS asks about with a permission prompt, relative to home:
    /// Files and Folders (Desktop, Documents, Downloads), iCloud Drive, and
    /// the Music and TV media libraries. Other apps' containers prompt too;
    /// `skipped(in:entries:)` handles those.
    static let prompting: Set<String> = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Mobile Documents",
        "Movies/TV",
        "Music",
    ]

    /// Folders macOS refuses without a prompt, relative to home.
    static let folders: Set<String> = [
        ".Trash",
        "Library/Accounts",
        "Library/AppleMediaServices",
        "Library/Assistant/SiriVocabulary",
        "Library/Autosave Information",
        "Library/Biome",
        "Library/com.apple.aiml.instrumentation",
        "Library/ContainerManager",
        "Library/Cookies",
        "Library/CoreFollowUp",
        "Library/Daemon Containers",
        "Library/DoNotDisturb",
        "Library/DuetExpertCenter",
        "Library/HomeKit",
        "Library/IdentityServices",
        "Library/IntelligencePlatform",
        "Library/Mail",
        "Library/Messages",
        "Library/PersonalizationPortrait",
        "Library/Safari",
        "Library/Sharing",
        "Library/Shortcuts",
        "Library/StatusKit",
        "Library/Suggestions",
        "Library/Trial",
        "Library/Weather",
        "Library/Metadata/CoreSpotlight",
        "Library/Metadata/com.apple.IntelligentSuggestions",
        "Library/Application Support/AddressBook",
        "Library/Application Support/BraveSoftware/Brave-Browser",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions",
        "Library/Application Support/CloudDocs",
        "Library/Application Support/com.apple.avfoundation/Frecents",
        "Library/Application Support/com.apple.sharedfilelist",
        "Library/Application Support/DifferentialPrivacy",
        "Library/Application Support/discord",
        "Library/Application Support/FaceTime",
        "Library/Application Support/FileProvider",
        "Library/Application Support/Firefox",
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Knowledge",
        "Library/Application Support/Microsoft Edge",
        "Library/Application Support/MobileSync",
        "Library/Caches/CloudKit",
        "Library/Caches/com.apple.ap.adprivacyd",
        "Library/Caches/com.apple.containermanagerd",
        "Library/Caches/com.apple.homed",
        "Library/Caches/com.apple.HomeKit",
        "Library/Caches/com.apple.Safari",
        "Library/Caches/com.apple.Safari.SafeBrowsing",
        "Library/Caches/FamilyCircle",
        "Library/Caches/familycircled",
        "Pictures/Photo Booth Library",
    ]

    /// Subfolders of a folder (path components relative to the account's
    /// home) to skip without Full Disk Access.
    static func skipped(in relative: [String], entries: [DirectoryEntry]) -> [String] {
        entries.compactMap { entry in
            entry.kind == .directory && isProtected(entry.name, in: relative) ? entry.name : nil
        }
    }

    /// Whether the folder `name` inside `parent` (components relative to
    /// the account's home) is protected.
    static func isProtected(_ name: String, in parent: [String]) -> Bool {
        switch parent {
        // Other apps' data. 147 of 149 group containers, and 329 of 338
        // refused containers were Apple's; since macOS 14 reading any
        // other app's container can also ask for permission, so all of
        // them wait for Full Disk Access.
        case ["Library", "Group Containers"], ["Library", "Containers"]:
            return true
        case ["Pictures"] where name.lowercased().hasSuffix(".photoslibrary"):
            return true
        default:
            let path = (parent + [name]).joined(separator: "/")
            return folders.contains(path) || prompting.contains(path)
        }
    }

    /// Components of `path` below the account's home, or nil when it isn't
    /// inside it. Protection follows where a folder really is, not where a
    /// scan started: `Documents` in any other folder is just a folder.
    static func relative(_ path: String, to accountHome: String) -> [String]? {
        if path == accountHome { return [] }
        guard path.hasPrefix(accountHome + "/") else { return nil }
        return path.dropFirst(accountHome.count + 1).split(separator: "/").map(String.init)
    }

    /// Whether `path` is a protected folder or inside one.
    static func covers(_ path: String, accountHome: String) -> Bool {
        guard let components = relative(path, to: accountHome) else { return false }
        return components.indices.contains { isProtected(components[$0], in: Array(components[..<$0])) }
    }
}
