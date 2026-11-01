import Foundation

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

/// Measures and applies a contents policy, for the scanner and the cleaner.
enum ContentsSurvey {
    /// What the policy would delete under `path`: its bytes, and those
    /// bytes per entry directly inside, for the breakdown.
    static func measure(
        _ policy: ContentsPolicy, _ path: String, now: Date
    ) -> (bytes: Int64, children: [SizedDirectory<DirectoryMatch>.Child]) {
        switch policy {
        case .agedFiles(let minimumAge):
            guard let survey = AgedFiles(minimumAge: minimumAge, now: now).survey(path) else { return (0, []) }
            return (survey.bytes, survey.byChild.map { .init(name: $0.key, bytes: $0.value, isDirectory: true) })
        case .allExcept(let kept):
            guard let entries = try? DirectoryReader().entries(atPath: path) else { return (0, []) }
            var children: [SizedDirectory<DirectoryMatch>.Child] = []
            for entry in entries where !kept.contains(entry.name) {
                var bytes = entry.allocatedSize
                if entry.kind == .directory {
                    bytes = (try? Walker(root: path + "/" + entry.name, delegate: SizeOnly()).run().totalBytes) ?? bytes
                } else if entry.kind == .symlink {
                    var info = stat()
                    bytes = lstat(path + "/" + entry.name, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
                }
                children.append(.init(name: entry.name, bytes: bytes, isDirectory: entry.kind == .directory))
            }
            return (children.reduce(0) { $0 + $1.bytes }, children)
        }
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
    /// Names that couldn't be removed.
    var failures: [String] = []
    private let reader = DirectoryReader()

    mutating func remove(_ name: String, in parent: Int32) {
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
            var fd: Int32
            repeat { fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } while fd < 0 && errno == EINTR
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
            for entry in entries { remove(entry.name, in: fd) }
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

/// Regular files old enough to delete under a folder, found and deleted
/// through file descriptors: each folder is opened relative to its parent
/// with O_NOFOLLOW, so a symlink is never followed, and nothing on another
/// device (a disk mounted inside) is entered.
struct AgedFiles {
    /// Lists an open directory. Replaceable in tests to make a listing
    /// incomplete.
    typealias Lister = (_ fd: Int32, _ reader: DirectoryReader) throws(POSIXError) -> DirectoryListing

    var minimumAge: TimeInterval
    var now: Date
    var lister: Lister = { fd, reader throws(POSIXError) in try reader.listing(directory: fd) }

    /// What a pass found or did.
    struct Outcome: Sendable, Hashable {
        /// Eligible files: found by a survey, deleted by `remove`.
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

    /// Finds the eligible files without changing anything.
    func survey(_ root: String) -> Outcome? {
        guard let fd = try? DirectoryReader.openDirectory(root) else { return nil }
        return walk(fd, root: root, delete: false)
    }

    /// Deletes the eligible files under `root`, checking each again right
    /// before. `root` is opened from `home` one component at a time with
    /// O_NOFOLLOW, so no symlink at or above it is followed.
    func remove(_ root: String, home: String) -> Outcome? {
        guard let fd = Self.openBeneath(home, root) else { return nil }
        return walk(fd, root: root, delete: true)
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
    private func walk(_ rootFD: Int32, root: String, delete: Bool) -> Outcome? {
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(rootFD)
            return nil
        }
        let device = Int64(info.st_dev)
        var outcome = Outcome()
        let reader = DirectoryReader()
        // Depth first, holding one descriptor per level.
        func visit(_ fd: Int32, path: String, top: String?) {
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
                    var sub: Int32
                    repeat {
                        sub = openat(fd, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    } while sub < 0 && errno == EINTR
                    guard sub >= 0 else {
                        if errno != ENOENT { outcome.unreadableFolders += 1 }
                        continue
                    }
                    var opened = stat()
                    guard fstat(sub, &opened) == 0, Int64(opened.st_dev) == device else {
                        close(sub)
                        continue
                    }
                    visit(sub, path: path + "/" + entry.name, top: child)
                case .file:
                    guard isEligible(
                        kind: .file, links: UInt64(entry.linkCount), device: Int64(entry.device),
                        rootDevice: device, modified: entry.modified)
                    else { continue }
                    if delete {
                        // Checked again through the descriptor: still the
                        // same regular file, still old enough.
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
                    } else {
                        outcome.files += 1
                        outcome.bytes += entry.allocatedSize
                        outcome.byChild[child, default: 0] += entry.allocatedSize
                    }
                case .symlink, .other:
                    continue
                }
            }
        }
        visit(rootFD, path: root, top: nil)
        return outcome
    }
}
