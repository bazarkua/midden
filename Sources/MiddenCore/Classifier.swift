import Foundation

// Classification happens when a directory is entered, using only what is
// already in hand: its path relative to home, its own listing, and a few
// facts its parent's listing handed down. The scanner and the cleaner both
// classify through this file, so the cleaner can't approve anything the
// scanner wouldn't have reported.

/// Where a directory sits, inherited from its ancestors.
struct Scope: Sendable, Hashable {
    /// An ancestor covers its whole subtree (a finding, a .git folder, a
    /// library package): nothing inside is reported on its own.
    var claimed = false
    /// Inside ~/Library.
    var inLibrary = false
    /// Inside a top-level hidden folder such as ~/.vscode or ~/.nvm.
    var inDotFolder = false
    /// Inside a container (a rule's folder that other rules match folders
    /// in): only those rules apply here, and whatever they don't match
    /// belongs to the container.
    var owned = false
}

/// What a directory's listing tells about it as a project, for classifying
/// its subdirectories (is `target` next to a Cargo.toml?).
struct ProjectFacts: Sendable, Hashable {
    struct Markers: OptionSet, Sendable, Hashable {
        let rawValue: UInt16
        static let packageJSON = Markers(rawValue: 1 << 0)
        static let cargoToml = Markers(rawValue: 1 << 1)
        static let podfile = Markers(rawValue: 1 << 2)
        static let gradle = Markers(rawValue: 1 << 3)
        static let pubspec = Markers(rawValue: 1 << 4)
        static let pnpmLock = Markers(rawValue: 1 << 5)
        static let yarnLock = Markers(rawValue: 1 << 6)
        static let bunLock = Markers(rawValue: 1 << 7)
        static let uvLock = Markers(rawValue: 1 << 8)
        static let pythonRequirements = Markers(rawValue: 1 << 9)
        /// Chromium's user data files: `Preferences`, and `Network
        /// Persistent State` or `TransportSecurity`.
        static let chromiumPreferences = Markers(rawValue: 1 << 10)
        static let chromiumNetworkState = Markers(rawValue: 1 << 11)
        static let swiftPackage = Markers(rawValue: 1 << 12)
    }

    var markers: Markers = []
    /// Newest modification time among the entries, ignoring build folders
    /// and Finder's .DS_Store. Seconds since 1970.
    var lastChange: Double?
    /// For a folder of versions (DeviceSupport): the subfolders that are
    /// the newest, or all of them when that can't be told. Nil elsewhere.
    var newestVersions: Set<String>?

    static let none = ProjectFacts()

    init(markers: Markers = [], lastChange: Double? = nil) {
        self.markers = markers
        self.lastChange = lastChange
    }

    /// Facts for the subfolders of a folder classified as `match`.
    init(entries: [DirectoryEntry], of match: DirectoryMatch?) {
        self.init(entries: entries)
        if case .rule(let rule)? = match, rule.rule.versionedChildren {
            newestVersions = DeviceSupportVersions.keepForReview(entries)
        }
    }

    init(entries: [DirectoryEntry]) {
        for entry in entries {
            // A marker is a regular file: a folder or a symlink named
            // package.json says nothing about the project.
            switch entry.kind == .file ? entry.name : "" {
            case "package.json": markers.insert(.packageJSON)
            case "Cargo.toml": markers.insert(.cargoToml)
            case "Podfile": markers.insert(.podfile)
            case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts":
                markers.insert(.gradle)
            case "pubspec.yaml": markers.insert(.pubspec)
            case "pnpm-lock.yaml": markers.insert(.pnpmLock)
            case "yarn.lock": markers.insert(.yarnLock)
            case "bun.lockb", "bun.lock": markers.insert(.bunLock)
            case "uv.lock": markers.insert(.uvLock)
            case "Package.swift": markers.insert(.swiftPackage)
            case "requirements.txt", "pyproject.toml", "Pipfile", "setup.py":
                markers.insert(.pythonRequirements)
            case "Preferences" where entry.kind == .file:
                markers.insert(.chromiumPreferences)
            case "Network Persistent State", "TransportSecurity":
                if entry.kind == .file { markers.insert(.chromiumNetworkState) }
            default: break
            }
            if entry.name == ".DS_Store" || BuildFolderKind.names.contains(entry.name) {
                continue
            }
            lastChange = max(lastChange ?? entry.modified, entry.modified)
        }
    }
}

/// What a directory is, when it's something Midden reports.
enum DirectoryMatch: Sendable {
    case rule(RuleMatch)
    case buildFolder(BuildFolderMatch)
    case worktree(WorktreeMatch)
}

/// Everything known about a directory when it's entered.
struct DirectoryFacts {
    var path: String
    var name: String
    /// Components relative to home; nil when deeper than any rule.
    var relative: [String]?
    /// Inherited from the parent.
    var scope: Scope
    /// From the parent's listing.
    var parent: ProjectFacts
    var entries: [DirectoryEntry]
}

/// A single file Midden reports.
enum FileMatch: Sendable, Hashable {
    case installer
    case largeFile
}

enum Classifier {
    static let largeFileBytes: Int64 = 1_000_000_000
    static let installerBytes: Int64 = 100_000_000
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "ipsw", "xip"]

    /// Bundles whose contents belong to the app that made them.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "lrdata",
    ]

    /// Classifies a directory (never the home folder itself) and returns the
    /// scope its contents inherit.
    static func classify(_ dir: DirectoryFacts) -> (match: DirectoryMatch?, inner: Scope) {
        var inner = dir.scope
        if inner.claimed { return (nil, inner) }
        if let relative = dir.relative, relative.count == 1 {
            inner.inLibrary = relative[0] == "Library"
            inner.inDotFolder = relative[0].hasPrefix(".")
        }
        if dir.name == ".git" {
            inner.claimed = true
            return (nil, inner)
        }
        if let relative = dir.relative, var match = RuleCatalog.match(relative, folder: dir) {
            if RuleCatalog.hasNestedRules(below: relative) {
                match.isContainer = true
                inner.owned = true
            } else if match.rule.claimsSubtree {
                inner.claimed = true
            }
            return (.rule(match), inner)
        }
        if inner.owned {
            // Not a rule's folder: part of the container, unless a rule
            // can still match further down.
            if !(dir.relative.map(RuleCatalog.hasNestedRules(below:)) ?? false) { inner.claimed = true }
            return (nil, inner)
        }
        if let gitDir = worktreeGitDir(dir) {
            inner.claimed = true
            return (.worktree(WorktreeMatch(path: dir.path, gitDir: gitDir)), inner)
        }
        // Build folders only where projects live: not in ~/Library, and not in
        // hidden tool folders like ~/.vscode/extensions or ~/.nvm, whose
        // node_modules are installed tools, not rebuildable project output.
        if !inner.inLibrary, !inner.inDotFolder,
            let kind = BuildFolderKind.detect(name: dir.name, parent: dir.parent, entries: dir.entries, path: dir.path)
        {
            inner.claimed = true
            let match = BuildFolderMatch(
                kind: kind, projectPath: (dir.path as NSString).deletingLastPathComponent,
                markers: dir.parent.markers, projectLastChange: dir.parent.lastChange)
            return (.buildFolder(match), inner)
        }
        if packageExtensions.contains((dir.name as NSString).pathExtension.lowercased()) {
            inner.claimed = true
        }
        return (nil, inner)
    }

    /// A linked worktree has a `.git` file, not a folder, saying
    /// `gitdir: <repository>/worktrees/<name>`. Submodules have one too, but
    /// it points into `<repository>/modules/`, so they're left alone.
    static func worktreeGitDir(_ dir: DirectoryFacts) -> String? {
        guard dir.entries.contains(where: { $0.name == ".git" && $0.kind == .file }),
            let text = readSmallFile(dir.path + "/.git"),
            let line = text.split(whereSeparator: \.isNewline).first,
            line.hasPrefix("gitdir:")
        else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !gitDir.isEmpty else { return nil }
        if !gitDir.hasPrefix("/") { gitDir = dir.path + "/" + gitDir }
        gitDir = normalize(gitDir)
        let parent = (gitDir as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent == "worktrees" ? gitDir : nil
    }

    /// Removes `.` and `..` components without resolving symlinks.
    static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// The first 4 KB of a regular file, not following symlinks.
    static func readSmallFile(_ path: String) -> String? {
        guard let fd = openRegularFile(path) else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var count: Int
        repeat { count = read(fd, &buffer, buffer.count) } while count < 0 && errno == EINTR
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count], as: UTF8.self)
    }

    /// Opens a regular file for reading, or returns nil. Doesn't follow a
    /// symlink at the last component (O_NOFOLLOW; ones above it are
    /// followed), and doesn't wait on a FIFO or device: the file can be
    /// swapped for a FIFO after it was listed, and open() of a FIFO waits
    /// for a writer forever. Reading a regular file can still block, on
    /// slow or hung storage.
    static func openRegularFile(_ path: String) -> Int32? {
        var fd: Int32
        repeat {
            fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        } while fd < 0 && errno == EINTR
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Classifies a file, given the scope of the directory holding it.
    static func classifyFile(_ entry: DirectoryEntry, in scope: Scope) -> FileMatch? {
        guard entry.kind == .file, !scope.claimed, !scope.owned, !scope.inLibrary,
            entry.allocatedSize >= installerBytes
        else { return nil }
        if installerExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
            return .installer
        }
        return entry.allocatedSize >= largeFileBytes ? .largeFile : nil
    }

    /// Subdirectories never entered, given a directory's relative path.
    /// File Provider folders (Dropbox, Google Drive, OneDrive...) can be slow
    /// and network-backed to list.
    static func excludedChildren(of relative: [String]?) -> [String] {
        relative == ["Library"] ? ["CloudStorage"] : []
    }
}

/// How the scanner would see one path, recomputed from scratch.
enum Reclassification {
    case directory(DirectoryMatch?, DirectoryFacts)
    case file(FileMatch?, DirectoryEntry, scope: Scope)
    /// Inside a folder that covers its subtree, so never reported on its own.
    case inside(ancestor: String, DirectoryMatch?)
    /// Not something the scanner enters: a symlink, another volume, a
    /// File Provider folder.
    case notScanned(String)
    case missing
}

extension Classifier {
    /// Lists every folder from `home` down to `relative` and classifies each
    /// level exactly as the scanner does, so the cleaner never relies on an
    /// earlier scan.
    static func reclassify(
        _ relative: [String], home: String, reader: DirectoryReader
    ) throws(POSIXError) -> Reclassification {
        var info = stat()
        guard lstat(home, &info) == 0 else { throw POSIXError(errno) }
        let homeDevice = info.st_dev

        var path = home
        var scope = Scope()
        /// The innermost container passed on the way down.
        var container: (path: String, match: DirectoryMatch)?
        var entries = try reader.entries(atPath: home)
        var facts = ProjectFacts(entries: entries)
        for (index, name) in relative.enumerated() {
            let parentRelative = Array(relative[..<index])
            guard let entry = entries.first(where: { $0.name == name }) else { return .missing }
            if excludedChildren(of: parentRelative).contains(name) {
                return .notScanned("Midden doesn't scan File Provider folders.")
            }
            let isLast = index == relative.count - 1
            switch entry.kind {
            case .file where isLast:
                return .file(classifyFile(entry, in: scope), entry, scope: scope)
            case .directory:
                break
            case .symlink:
                return .notScanned("It's a symbolic link.")
            default:
                return .notScanned("It's not a regular file or folder.")
            }
            guard entry.device == homeDevice else {
                return .notScanned("It's on another volume.")
            }
            path += "/" + name
            let childEntries = try reader.entries(atPath: path)
            let childRelative = Array(relative[...index])
            let dir = DirectoryFacts(
                path: path, name: name,
                relative: childRelative.count <= RuleCatalog.maxDepth ? childRelative : nil,
                scope: scope, parent: facts, entries: childEntries)
            let (match, inner) = classify(dir)
            // Inside a container, a folder no rule names is part of it.
            if scope.owned, case .none = match, let container {
                if isLast || inner.claimed { return .inside(ancestor: container.path, container.match) }
            }
            if isLast { return .directory(match, dir) }
            if inner.claimed && !scope.claimed { return .inside(ancestor: path, match) }
            if case .rule(let rule)? = match, rule.isContainer { container = (path, .rule(rule)) }
            scope = inner
            facts = ProjectFacts(entries: childEntries, of: match)
            entries = childEntries
        }
        return .missing
    }
}
