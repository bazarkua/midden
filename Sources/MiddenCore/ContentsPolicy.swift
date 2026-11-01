import Foundation
import Synchronization

/// How the cleaner empties a folder whose rule doesn't allow removing all
/// of its contents. Internal to the engine: the public action stays
/// `removeContents`, and the cleaner takes the policy from the rule it
/// matches again at clean time, never from the scan.
enum ContentsPolicy: Sendable, Hashable {
    /// Only regular files last modified at least this long ago. Every
    /// folder stays, with its identity, permissions and ACLs: macOS can't
    /// recreate some of them, such as Logs/DiagnosticReports.
    case agedFiles(minimumAge: TimeInterval)
    /// Everything directly inside except these names, as an owner's own
    /// clean command does (SwiftPM's `swift package clean`).
    case allExcept(Set<String>)
}

extension DirectoryMatch {
    /// How cleaning empties this folder, when not by removing all of it.
    var contentsPolicy: ContentsPolicy? {
        switch self {
        case .rule(let match): match.rule.contents
        case .buildFolder(let match): match.kind.contents
        case .worktree: nil
        }
    }
}

/// What a contents policy would delete under its folder, and whether every
/// folder inside was read to say so.
struct ContentsMeasure: Sendable {
    var bytes: Int64
    /// Those bytes per entry directly inside the folder, for the breakdown.
    var children: [SizedDirectory<DirectoryMatch>.Child]
    /// Folders inside that weren't listed, or only partly: their share is
    /// missing from `bytes`.
    var unread: Int

    var isComplete: Bool { unread == 0 }

    /// Nothing could be read.
    static let unknown = ContentsMeasure(bytes: 0, children: [], unread: 1)
}

/// Adds up what a contents policy would delete from listings a walk makes
/// anyway: the scan's own walk, under its admission, watchdog and
/// cancellation, or the cleaner's measuring walk. No folder is listed just
/// for this. Every folder inside that the walk should have listed is
/// counted, and every one it listed, so one it gave up, couldn't open or
/// read only partly leaves the measure visibly incomplete.
final class ContentsTally: Sendable {
    let root: String
    let policy: ContentsPolicy
    /// Seconds since 1970 that file ages are measured from.
    let now: Double
    /// The walk's device: it lists no folder on another one.
    let device: Int32

    private struct State {
        var bytes: Int64 = 0
        var children: [String: (bytes: Int64, isDirectory: Bool)] = [:]
        /// Folders inside the walk will list, and those it did.
        var expected = 0
        var visited = 0
        /// Folders listed only partly, or on another device where the
        /// policy needs them.
        var partial = 0
        /// Files with several links, counted once.
        var linked: Set<UInt64> = []
    }

    private let state = Mutex(State())

    init(root: String, policy: ContentsPolicy, now: Date, device: Int32) {
        self.root = root
        self.policy = policy
        self.now = now.timeIntervalSince1970
        self.device = device
    }

    /// Adds one listed folder: the policy's folder itself, or one inside it.
    /// - Parameter skipped: subfolders the walk won't list (unreadable ones).
    func add(path: String, entries: [DirectoryEntry], isComplete: Bool, skipped: [String] = []) {
        let isRoot = path == root
        let top = isRoot ? nil : path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
        state.withLock { state in
            func count(_ name: String, _ bytes: Int64, directory: Bool) {
                state.bytes += bytes
                state.children[name, default: (0, directory)].bytes += bytes
            }
            func listsSubfolder(_ entry: DirectoryEntry) -> Bool {
                entry.kind == .directory && entry.device == device && !skipped.contains(entry.name)
            }
            switch policy {
            case .agedFiles(let minimumAge):
                for entry in entries {
                    if listsSubfolder(entry) { state.expected += 1 }
                    guard entry.kind == .file, entry.linkCount == 1, entry.modified > 0,
                        now - entry.modified >= minimumAge
                    else { continue }
                    count(top ?? entry.name, entry.allocatedSize, directory: top != nil)
                }
            case .allExcept(let kept):
                if let top, kept.contains(top) { return }  // Kept: never measured.
                for entry in entries {
                    if isRoot, kept.contains(entry.name) { continue }
                    let name = top ?? entry.name
                    if entry.kind == .directory {
                        // Removed with everything in it, so a folder the
                        // walk won't enter leaves the measure incomplete.
                        if listsSubfolder(entry) { state.expected += 1 } else { state.partial += 1 }
                        count(name, entry.allocatedSize, directory: true)
                    } else {
                        if entry.linkCount > 1, !state.linked.insert(entry.inode).inserted { continue }
                        count(name, entry.allocatedSize, directory: top != nil)
                    }
                }
            }
            if !isRoot { state.visited += 1 }
            if !isComplete { state.partial += 1 }
        }
    }

    var measure: ContentsMeasure {
        state.withLock { state in
            ContentsMeasure(
                bytes: state.bytes,
                children: state.children.map { .init(name: $0.key, bytes: $0.value.bytes, isDirectory: $0.value.isDirectory) },
                unread: max(state.expected - state.visited, 0) + state.partial)
        }
    }
}

/// Opens a folder relative to an open parent, without following a symlink.
/// Returns the descriptor, or -1 with errno set. Replaceable in tests, to
/// run out of descriptors on purpose.
typealias FolderOpener = (_ parent: Int32, _ name: String) -> Int32

/// The deletion walks hold one descriptor per level they're in, so how
/// deep they go is also how many descriptors they hold. Past this depth
/// they don't go further, and say so.
let deletionDepthLimit = 128

func openFolder(_ parent: Int32, _ name: String) -> Int32 {
    var fd: Int32
    repeat { fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } while fd < 0 && errno == EINTR
    return fd
}

/// Measures and applies a contents policy, for the scanner and the cleaner.
enum ContentsSurvey {
    /// A listing function with the walker's signature.
    typealias Lister = @Sendable (_ path: String, _ reader: DirectoryReader) throws(POSIXError) -> DirectoryListing

    /// What the policy would delete under `path` now, measured by a walk
    /// with the walker's watchdog and thread admission, for the cleaner.
    /// (The scan measures during its own walk instead.)
    static func measure(
        _ policy: ContentsPolicy, _ path: String, now: Date,
        stallTimeout: TimeInterval = WalkDefaults.stallTimeout,
        lister: @escaping Lister = { path, reader throws(POSIXError) in try reader.listing(atPath: path) }
    ) -> ContentsMeasure {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .unknown }
        let tally = ContentsTally(root: path, policy: policy, now: now, device: info.st_dev)
        let walker = Walker(
            root: path, delegate: TallyDelegate(tally: tally), threadCount: 2, stallTimeout: stallTimeout,
            lister: lister)
        guard let walk = try? walker.run(), walk.rootError == nil else { return .unknown }
        return tally.measure
    }

    /// Deletes what the policy allows. Returns what went wrong, if
    /// anything, and the bytes deleted.
    /// - Parameter home: the folder `path` is opened from, one component
    ///   at a time, so a symlink swapped in above it isn't followed either.
    static func clean(
        _ policy: ContentsPolicy, _ path: String, home: String, now: Date
    ) -> (failure: String?, deleted: Int64?) {
        switch policy {
        case .agedFiles(let minimumAge):
            guard let outcome = AgedFiles(minimumAge: minimumAge, now: now).remove(path, home: home) else {
                return ("Midden couldn't open the folder.", 0)
            }
            var problems: [String] = []
            if !outcome.failures.isEmpty {
                let name = (outcome.failures[0] as NSString).lastPathComponent
                problems.append("couldn't delete \(outcome.failures.count) old \(outcome.failures.count == 1 ? "file" : "files"), such as \(name)")
            }
            if outcome.unreadableFolders > 0 {
                let count = outcome.unreadableFolders
                problems.append("couldn't read \(count) \(count == 1 ? "folder" : "folders") inside, so \(count == 1 ? "its" : "their") files were left alone")
            }
            if outcome.tooDeep > 0 {
                let count = outcome.tooDeep
                problems.append("didn't go into \(count) \(count == 1 ? "folder" : "folders") nested more than \(deletionDepthLimit) levels deep")
            }
            guard !problems.isEmpty else { return (nil, outcome.bytes) }
            let deleted = "Deleted \(outcome.files) old \(outcome.files == 1 ? "file" : "files")"
            return (deleted + ", but " + problems.joined(separator: " and ") + ".", outcome.bytes)
        case .allExcept(let kept):
            guard let fd = AgedFiles.openBeneath(home, path) else { return ("Midden couldn't open the folder.", 0) }
            defer { close(fd) }
            var tree = TreeRemoval()
            guard let entries = try? DirectoryReader().entries(directory: fd) else {
                return ("Midden couldn't read the folder.", 0)
            }
            for entry in entries where !kept.contains(entry.name) {
                tree.remove(entry.name, in: fd)
            }
            guard let failure = tree.failures.first else { return (nil, tree.bytes) }
            return ("Couldn't remove \(tree.failures.count) \(tree.failures.count == 1 ? "item" : "items"), such as \(failure).", tree.bytes)
        }
    }
}

/// Removes a file or a folder with everything in it through descriptors:
/// each folder is opened relative to its parent with O_NOFOLLOW, a symlink
/// is removed itself and never followed, and nothing on another device (a
/// disk mounted inside) is entered, so removing the folder holding it fails
/// instead.
struct TreeRemoval {
    /// Bytes freed: allocated blocks of what was removed, files with other
    /// names left uncounted.
    var bytes: Int64 = 0
    /// Names that couldn't be removed. A folder holding one stays too.
    var failures: [String] = []
    /// Levels below the first folder it goes into, at most; see
    /// `deletionDepthLimit`. Deeper folders stay, and count as failures.
    var maxDepth = deletionDepthLimit
    var open: FolderOpener = openFolder
    private let reader = DirectoryReader()

    mutating func remove(_ name: String, in parent: Int32) {
        remove(name, in: parent, depth: 0)
    }

    private mutating func remove(_ name: String, in parent: Int32, depth: Int) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno != ENOENT { failures.append(name) }
            return
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, parentInfo.st_dev == info.st_dev else {
                failures.append(name)
                return
            }
            // Too deep: one more descriptor held per level. Out of
            // descriptors (EMFILE) fails the same way: the folder stays.
            guard depth < maxDepth else {
                failures.append(name)
                return
            }
            let fd = open(parent, name)
            guard fd >= 0 else {
                failures.append(name)
                return
            }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
                let entries = try? reader.entries(directory: fd)
            else {
                close(fd)
                failures.append(name)
                return
            }
            let before = failures.count
            for entry in entries { remove(entry.name, in: fd, depth: depth + 1) }
            close(fd)
            if failures.count > before { return }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                failures.append(name)
                return
            }
            bytes += Int64(info.st_blocks) * 512
        } else {
            guard unlinkat(parent, name, 0) == 0 else {
                if errno != ENOENT { failures.append(name) }
                return
            }
            if info.st_nlink <= 1 { bytes += Int64(info.st_blocks) * 512 }
        }
    }
}

/// Deletes the regular files old enough under a folder, through file
/// descriptors: each folder is opened relative to its parent
/// with O_NOFOLLOW, so a symlink is never followed, and nothing on another
/// device (a disk mounted inside) is entered.
struct AgedFiles {
    /// Lists an open directory. Replaceable in tests to make a listing
    /// incomplete.
    typealias Lister = (_ fd: Int32, _ reader: DirectoryReader) throws(POSIXError) -> DirectoryListing

    var minimumAge: TimeInterval
    var now: Date
    var lister: Lister = { fd, reader throws(POSIXError) in try reader.listing(directory: fd) }
    /// Levels below the root it goes into, at most; see
    /// `deletionDepthLimit`. Deeper folders are left alone and counted.
    var maxDepth = deletionDepthLimit
    var open: FolderOpener = openFolder

    /// What a pass found or did.
    struct Outcome: Sendable, Hashable {
        /// Eligible files deleted.
        var files = 0
        /// Their allocated bytes.
        var bytes: Int64 = 0
        /// Eligible bytes per entry directly inside the root, for the
        /// finding's breakdown.
        var byChild: [String: Int64] = [:]
        /// Folders that couldn't be opened or listed completely. Their
        /// files, or the ones not listed, were left alone.
        var unreadableFolders = 0
        /// Files that were eligible but couldn't be deleted, by name.
        var failures: [String] = []
        /// Folders deeper than `maxDepth`, not gone into.
        var tooDeep = 0
    }

    /// Whether a listed entry may be deleted: a regular file with one link
    /// (another name would keep its data), on the root's device, with a
    /// known modification time at least `minimumAge` in the past. A date
    /// in the future or at 0 says nothing reliable about its age.
    func isEligible(kind: DirectoryEntry.Kind, links: UInt64, device: Int64, rootDevice: Int64, modified: Double) -> Bool {
        guard kind == .file, links == 1, device == rootDevice, modified > 0 else { return false }
        let age = now.timeIntervalSince1970 - modified
        return age >= minimumAge
    }

    /// Deletes the eligible files under `root`, checking each again right
    /// before. `root` is opened from `home` one component at a time with
    /// O_NOFOLLOW, so no symlink at or above it is followed.
    func remove(_ root: String, home: String) -> Outcome? {
        guard let fd = Self.openBeneath(home, root) else { return nil }
        return walk(fd, root: root)
    }

    /// Opens `path`, which must be inside `home`, walking down from `home`
    /// without following a symlink at any step.
    static func openBeneath(_ home: String, _ path: String) -> Int32? {
        guard path.hasPrefix(home + "/") else { return nil }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        guard var fd = try? DirectoryReader.openDirectory(home) else { return nil }
        for component in path.dropFirst(home.count + 1).split(separator: "/") {
            var next: Int32
            repeat { next = openat(fd, String(component), flags) } while next < 0 && errno == EINTR
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    /// Walks from an open root, which it closes. Nil when the root isn't a
    /// folder.
    private func walk(_ rootFD: Int32, root: String) -> Outcome? {
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(rootFD)
            return nil
        }
        let device = Int64(info.st_dev)
        var outcome = Outcome()
        let reader = DirectoryReader()
        // Depth first, holding one descriptor per level.
        func visit(_ fd: Int32, path: String, top: String?, depth: Int) {
            defer { close(fd) }
            let listing: DirectoryListing
            do {
                listing = try lister(fd, reader)
            } catch {
                outcome.unreadableFolders += 1
                return
            }
            if !listing.isComplete { outcome.unreadableFolders += 1 }
            for entry in listing.entries {
                let child = top ?? entry.name
                switch entry.kind {
                case .directory:
                    // Another device: a disk mounted here. Never entered.
                    guard Int64(entry.device) == device else { continue }
                    guard depth < maxDepth else {
                        outcome.tooDeep += 1
                        continue
                    }
                    // EMFILE (out of descriptors) counts as unreadable: the
                    // folder's files stay, and the result says so.
                    let sub = open(fd, entry.name)
                    guard sub >= 0 else {
                        if errno != ENOENT { outcome.unreadableFolders += 1 }
                        continue
                    }
                    var opened = stat()
                    guard fstat(sub, &opened) == 0, Int64(opened.st_dev) == device else {
                        close(sub)
                        continue
                    }
                    visit(sub, path: path + "/" + entry.name, top: child, depth: depth + 1)
                case .file:
                    guard isEligible(
                        kind: .file, links: UInt64(entry.linkCount), device: Int64(entry.device),
                        rootDevice: device, modified: entry.modified)
                    else { continue }
                    // Checked again through the descriptor: still the same
                    // regular file, still old enough.
                    var current = stat()
                    guard fstatat(fd, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                        current.st_ino == entry.inode,
                        isEligible(
                            kind: current.st_mode & S_IFMT == S_IFREG ? .file : .other,
                            links: UInt64(current.st_nlink), device: Int64(current.st_dev),
                            rootDevice: device,
                            modified: Double(current.st_mtimespec.tv_sec))
                    else { continue }
                    guard unlinkat(fd, entry.name, 0) == 0 else {
                        if errno != ENOENT { outcome.failures.append(path + "/" + entry.name) }
                        continue
                    }
                    let bytes = Int64(current.st_blocks) * 512
                    outcome.files += 1
                    outcome.bytes += bytes
                    outcome.byChild[child, default: 0] += bytes
                case .symlink, .other:
                    continue
                }
            }
        }
        visit(rootFD, path: root, top: nil, depth: 0)
        return outcome
    }
}

/// Feeds every folder a measuring walk lists to a tally.
private struct TallyDelegate: WalkDelegate {
    let tally: ContentsTally

    func rootContext() {}

    func visit(_ directory: VisitedDirectory<Void>) -> Visit<Void, Never> {
        tally.add(path: directory.path, entries: directory.entries, isComplete: directory.isComplete)
        return Visit(mark: nil, childContext: ())
    }
}
