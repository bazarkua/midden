import Foundation

// The data contract between the engine and its front ends (CLI, app).
// Everything here is a plain value type so a report can be encoded to JSON
// (`midden scan --json`) and read back by any front end unchanged.

/// How sure Midden is that deleting something is harmless.
public enum Safety: String, Codable, Sendable, CaseIterable, Comparable {
    /// The owning tool or app recreates it on its own. Picked by "Clean safe items".
    case safe
    /// Deletable, but it has a cost worth a look first: a rebuild, a large
    /// re-download, or activity in the last few days.
    case review
    /// Never deleted by Midden on its own: your own files, or things that
    /// must be cleaned inside the app that owns them. Your own large files
    /// can be moved to the Trash when you choose to.
    case info

    public static func < (lhs: Safety, rhs: Safety) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .info: 2
        }
    }
}

/// The groups findings are shown in.
public enum Category: String, Codable, Sendable, CaseIterable, Identifiable {
    case worktrees
    case buildFolders
    case developerTools
    case packageCaches
    case appCaches
    case system
    case largeFiles
    case personal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worktrees: "Git worktrees"
        case .buildFolders: "Build folders"
        case .developerTools: "Developer tools"
        case .packageCaches: "Package caches"
        case .appCaches: "App caches"
        case .system: "Logs and Trash"
        case .largeFiles: "Large files"
        case .personal: "Your files"
        }
    }

    public var summary: String {
        switch self {
        case .worktrees: "Extra checkouts of your repositories, often left behind by AI coding tools."
        case .buildFolders: "node_modules, target, .next and other folders a build recreates."
        case .developerTools: "Xcode, simulators, Android and Docker data."
        case .packageCaches: "Downloads kept by npm, Gradle, Cargo, uv and other package managers."
        case .appCaches: "Files apps keep to load faster. They rebuild them as needed."
        case .system: "Log files and the Trash."
        case .largeFiles: "Single files over 1 GB, and installers you may no longer need."
        case .personal: "Your own data. Midden explains it and never deletes it for you."
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .worktrees: "arrow.triangle.branch"
        case .buildFolders: "hammer"
        case .developerTools: "wrench.and.screwdriver"
        case .packageCaches: "shippingbox"
        case .appCaches: "square.stack.3d.up"
        case .system: "doc.text"
        case .largeFiles: "doc.zipper"
        case .personal: "person.crop.square"
        }
    }
}

/// What cleaning a finding does.
public enum CleanAction: Codable, Sendable, Hashable {
    /// Delete the folder itself.
    case removeDirectory
    /// Empty the folder but keep it, for locations an app expects to exist.
    case removeContents
    /// Delete a single file.
    case removeFile
    /// Run the owning tool's own command, e.g. `git worktree remove`, so the
    /// tool can refuse if something is wrong.
    case run([String])
    /// Move a file of yours to the Trash, where you can still get it back.
    /// Its space comes back when the Trash is emptied.
    case moveToTrash
    /// Midden won't delete this. The string says how to do it by hand.
    case manual(String)

    /// Whether Midden can perform this action itself.
    public var isAutomatic: Bool {
        if case .manual = self { return false }
        return true
    }
}

/// One check Midden ran before calling something safe, shown to the user so
/// the verdict is explainable. Example: "No uncommitted changes".
public struct SafetyCheck: Codable, Sendable, Hashable {
    /// What is checked, stable across versions while titles may be reworded:
    /// worktrees use "uncommitted", "ignoredFiles", "hiddenChanges", "onBranch",
    /// "locked", "inUse", "lastActivity", "gitInstalled", "gitReadable",
    /// "repositoryExists", "worktreeRecorded";
    /// build folders "projectIdle", "packagesRecorded"; simulators
    /// "simulatorUnavailable". Findings that a running program can depend
    /// on (pnpm dlx packages, browser profiles, Homebrew downloads, SwiftPM
    /// build products and others) also use "inUse", and findings that delete
    /// only part of a folder (Logs, SwiftPM build products) "measured". Empty for checks saved
    /// before ids existed.
    public var id: String
    public var title: String
    public var passed: Bool
    public var detail: String

    public init(id: String = "", title: String, passed: Bool, detail: String) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }

    /// Also reads checks saved before `id` existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decode(String.self, forKey: .title)
        passed = try container.decode(Bool.self, forKey: .passed)
        detail = try container.decode(String.self, forKey: .detail)
    }
}

/// A named part of a finding's size, e.g. the `node_modules` inside a worktree.
public struct Slice: Codable, Sendable, Hashable {
    public var name: String
    public var bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// The app whose data a finding belongs to, so the UI can ask the user to
/// quit it before cleaning.
public struct AppHint: Codable, Sendable, Hashable {
    public var name: String?
    public var bundleID: String?

    public init(name: String? = nil, bundleID: String? = nil) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// Something Midden found that takes space, with the reasoning behind its verdict.
public struct Finding: Identifiable, Codable, Sendable, Hashable {
    /// Absolute path for file-system findings, `sim:<UDID>` for simulators.
    public var id: String
    public var category: Category
    public var title: String
    public var path: String
    /// What the finding belongs to, for drilling down: a repository, project,
    /// app or tool name.
    public var group: String
    /// Bytes actually allocated on disk, hard links counted once.
    public var bytes: Int64
    public var safety: Safety
    /// Plain-language explanation of what this is and what deleting it costs.
    public var explanation: String
    public var checks: [SafetyCheck]
    public var action: CleanAction
    public var app: AppHint?
    public var lastActivity: Date?
    /// Largest parts of this finding, biggest first.
    public var breakdown: [Slice]

    public init(
        id: String,
        category: Category,
        title: String,
        path: String,
        group: String,
        bytes: Int64,
        safety: Safety,
        explanation: String,
        checks: [SafetyCheck] = [],
        action: CleanAction,
        app: AppHint? = nil,
        lastActivity: Date? = nil,
        breakdown: [Slice] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.path = path
        self.group = group
        self.bytes = bytes
        self.safety = safety
        self.explanation = explanation
        self.checks = checks
        self.action = action
        self.app = app
        self.lastActivity = lastActivity
        self.breakdown = breakdown
    }
}

/// Size of a top-level folder in the home directory, for "where your space goes".
public struct FolderUsage: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var bytes: Int64

    public init(path: String, name: String, bytes: Int64) {
        self.path = path
        self.name = name
        self.bytes = bytes
    }
}

/// A file or folder in the home folder's size tree, for the space map.
public struct SpaceNode: Codable, Sendable, Hashable {
    /// The item's name, or "Other (N items)" for merged small items.
    public var name: String
    /// Unique in the tree. A merged node's is its parent's path plus
    /// "/(other)".
    public var path: String
    /// Bytes allocated on disk, hard links counted once.
    public var bytes: Int64
    public var isDirectory: Bool
    /// Set on the finding's own node only. Findings are never merged into
    /// "Other", and the folders leading to them are always kept.
    public var findingID: String?
    /// Largest first. When present, they add up to `bytes`.
    public var children: [SpaceNode]
    /// Small items merged into one node.
    public var isOther: Bool

    public init(
        name: String, path: String, bytes: Int64, isDirectory: Bool, findingID: String? = nil,
        children: [SpaceNode] = [], isOther: Bool = false
    ) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.findingID = findingID
        self.children = children
        self.isOther = isOther
    }

    /// Also reads trees saved before `isOther` existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        findingID = try container.decodeIfPresent(String.self, forKey: .findingID)
        children = try container.decode([SpaceNode].self, forKey: .children)
        isOther = try container.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
    }
}

public struct DiskSpace: Codable, Sendable, Hashable {
    public var total: Int64
    public var free: Int64
    /// The volume's name as Finder shows it, e.g. "Macintosh HD".
    public var volumeName: String?

    public init(total: Int64, free: Int64, volumeName: String? = nil) {
        self.total = total
        self.free = free
        self.volumeName = volumeName
    }
}

public struct ScanReport: Codable, Sendable {
    public var home: String
    public var startedAt: Date
    /// Seconds.
    public var duration: Double
    public var itemsScanned: Int64
    public var bytesScanned: Int64
    public var disk: DiskSpace
    /// Sorted by size, largest first.
    public var findings: [Finding]
    public var topFolders: [FolderUsage]
    /// Folders the scan didn't read:
    /// `skippedWithoutFullDiskAccess + readErrors`.
    public var unreadableCount: Int
    public var needsFullDiskAccess: Bool
    /// The home folder's size tree, root = home. Worktrees outside home
    /// aren't in it.
    public var spaceMap: SpaceNode?
    /// Privacy-protected folders not opened because Full Disk Access is
    /// missing. Granting it lets the next scan read them.
    public var skippedWithoutFullDiskAccess: Int
    /// Folders that failed to list (permissions, I/O errors), or whose
    /// listing stopped making progress and was given up.
    public var readErrors: Int
    /// Which privacy-protected folders were skipped for lack of Full Disk
    /// Access, relative to home and outermost first: "Desktop", "Documents",
    /// "Library/Mail". Lets a front end say what the scan left out.
    public var skippedFolders: [String]

    public init(
        home: String,
        startedAt: Date,
        duration: Double,
        itemsScanned: Int64,
        bytesScanned: Int64,
        disk: DiskSpace,
        findings: [Finding],
        topFolders: [FolderUsage],
        unreadableCount: Int,
        needsFullDiskAccess: Bool,
        spaceMap: SpaceNode? = nil,
        skippedWithoutFullDiskAccess: Int = 0,
        readErrors: Int = 0,
        skippedFolders: [String] = []
    ) {
        self.home = home
        self.startedAt = startedAt
        self.duration = duration
        self.itemsScanned = itemsScanned
        self.bytesScanned = bytesScanned
        self.disk = disk
        self.findings = findings
        self.topFolders = topFolders
        self.unreadableCount = unreadableCount
        self.needsFullDiskAccess = needsFullDiskAccess
        self.spaceMap = spaceMap
        self.skippedWithoutFullDiskAccess = skippedWithoutFullDiskAccess
        self.readErrors = readErrors
        self.skippedFolders = skippedFolders
    }

    /// Also reads reports saved before the newer fields existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = try container.decode(String.self, forKey: .home)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        duration = try container.decode(Double.self, forKey: .duration)
        itemsScanned = try container.decode(Int64.self, forKey: .itemsScanned)
        bytesScanned = try container.decode(Int64.self, forKey: .bytesScanned)
        disk = try container.decode(DiskSpace.self, forKey: .disk)
        findings = try container.decode([Finding].self, forKey: .findings)
        topFolders = try container.decode([FolderUsage].self, forKey: .topFolders)
        unreadableCount = try container.decode(Int.self, forKey: .unreadableCount)
        needsFullDiskAccess = try container.decode(Bool.self, forKey: .needsFullDiskAccess)
        spaceMap = try container.decodeIfPresent(SpaceNode.self, forKey: .spaceMap)
        skippedWithoutFullDiskAccess =
            try container.decodeIfPresent(Int.self, forKey: .skippedWithoutFullDiskAccess) ?? 0
        readErrors = try container.decodeIfPresent(Int.self, forKey: .readErrors) ?? unreadableCount
        skippedFolders = try container.decodeIfPresent([String].self, forKey: .skippedFolders) ?? []
    }

    /// Bytes Midden could free for a given safety level.
    public func reclaimable(_ safety: Safety) -> Int64 {
        findings.lazy
            .filter { $0.safety == safety && $0.action.isAutomatic }
            .reduce(0) { $0 + $1.bytes }
    }
}

/// What a scan is doing, in order.
public enum ScanPhase: String, Codable, Sendable {
    case preparing, reading, worktrees, simulators, finishing
}

public struct ScanProgress: Sendable, Hashable {
    public var items: Int64
    public var bytes: Int64
    public var currentPath: String
    public var phase: ScanPhase
    /// Overall estimate, 0...1; nil when unknown. Never goes backwards and
    /// stays below 1: the returned report is the 100%.
    public var fraction: Double?
    /// Nil until the rate is stable, about 2 seconds into the scan.
    public var secondsRemaining: Double?
    /// What the phase is doing, as text that stays the same for the whole
    /// phase, e.g. "Checking worktrees". Counts are in `completed`/`total`.
    public var detail: String?
    /// Items done in a counted phase (worktrees); nil in other phases.
    public var completed: Int?
    /// Items the counted phase will do; fixed for the whole phase.
    public var total: Int?

    public init(
        items: Int64, bytes: Int64, currentPath: String, phase: ScanPhase = .reading,
        fraction: Double? = nil, secondsRemaining: Double? = nil, detail: String? = nil,
        completed: Int? = nil, total: Int? = nil
    ) {
        self.items = items
        self.bytes = bytes
        self.currentPath = currentPath
        self.phase = phase
        self.fraction = fraction
        self.secondsRemaining = secondsRemaining
        self.detail = detail
        self.completed = completed
        self.total = total
    }
}

public struct CleanResult: Codable, Sendable, Hashable {
    public var id: String
    public var ok: Bool
    /// Why it failed or was refused. Nil on success.
    public var message: String?
    /// Bytes deleted: the item's allocated size before cleaning minus what
    /// is left of it after. Free space reported by the volume can be too
    /// coarse to show this (in the App Sandbox it moves in 409.6 MB steps).
    /// Zero for items moved to the Trash: they still take space until the
    /// Trash is emptied.
    public var freedBytes: Int64
    /// The item went to the Trash instead of being deleted.
    public var movedToTrash: Bool

    public init(
        id: String, ok: Bool, message: String? = nil, freedBytes: Int64 = 0, movedToTrash: Bool = false
    ) {
        self.id = id
        self.ok = ok
        self.message = message
        self.freedBytes = freedBytes
        self.movedToTrash = movedToTrash
    }

    /// Also reads results saved before `freedBytes` and `movedToTrash` existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        freedBytes = try container.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0
        movedToTrash = try container.decodeIfPresent(Bool.self, forKey: .movedToTrash) ?? false
    }
}

public struct CleanSummary: Codable, Sendable {
    public var results: [CleanResult]
    public var freeBefore: Int64
    public var freeAfter: Int64

    public init(results: [CleanResult], freeBefore: Int64, freeAfter: Int64) {
        self.results = results
        self.freeBefore = freeBefore
        self.freeAfter = freeAfter
    }
}
