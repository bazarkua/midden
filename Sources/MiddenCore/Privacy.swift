import Foundation

/// Folders macOS guards with privacy permissions. Without Full Disk Access,
/// listing them fails, or open() waits on a permission prompt. When the Full
/// Disk Access probe fails, the scan skips them up front and counts them as
/// unreadable, instead of finding out one blocked call at a time (the
/// walker's watchdog still catches anything this list misses).
///
/// The list is every folder `du` couldn't read on a Mac without Full Disk
/// Access (macOS 27), plus the Photos and Music libraries.
enum PrivacyProtected {
    /// Paths relative to the home folder.
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
        "Music/Music",
        "Pictures/Photo Booth Library",
    ]

    /// Subfolders of a folder (path components relative to home) to skip
    /// without Full Disk Access.
    static func skipped(in relative: [String], entries: [DirectoryEntry]) -> [String] {
        let prefix = relative.isEmpty ? "" : relative.joined(separator: "/") + "/"
        return entries.compactMap { entry in
            guard entry.kind == .directory else { return nil }
            let name = entry.name
            switch relative {
            // Other apps' data: 147 of 149 group containers, and 329 of 338
            // protected containers were Apple's (the rest of Apple's held 1.7 MB).
            case ["Library", "Group Containers"]:
                return name
            case ["Library", "Containers"] where name.hasPrefix("com.apple."):
                return name
            case ["Pictures"] where name.lowercased().hasSuffix(".photoslibrary"):
                return name
            default:
                return folders.contains(prefix + name) ? name : nil
            }
        }
    }
}
