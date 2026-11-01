import Foundation
import Synchronization

/// Plugs the classifier into the walker: each directory is classified when
/// it's listed, and what its subdirectories need is handed down in the
/// walker's context.
final class ScanDelegate: WalkDelegate {
    struct Context: Sendable {
        /// The parent's path components relative to home, while the parent
        /// is shallow enough for a child to match a rule.
        var parentRelative: [String]?
        var scope: Scope
        /// From the parent's listing.
        var parent: ProjectFacts
    }

    struct FileHit: Sendable {
        var path: String
        var entry: DirectoryEntry
        var match: FileMatch
    }

    /// Skip privacy-protected folders: Full Disk Access is missing.
    let skipProtected: Bool
    /// The account home whose folders macOS protects. Protection goes by a
    /// folder's real location, so it doesn't depend on where the scan began.
    let accountHome: String?
    /// The scan's root, set when it's visited, to report skipped folders
    /// relative to it.
    private let scanRoot = Mutex<String?>(nil)
    private let fileHits = Mutex<[FileHit]>([])
    private let repositories = Mutex<[String]>([])
    private let skippedPaths = Mutex<[String]>([])

    var files: [FileHit] { fileHits.withLock { $0 } }

    /// `.git` folders that list linked worktrees, wherever the walk saw them.
    var gitDirectories: [String] { repositories.withLock { $0 } }

    /// Protected folders skipped for lack of Full Disk Access, relative to
    /// home: outermost first, then by name.
    var skippedFolders: [String] {
        skippedPaths.withLock { $0 }.sorted { lhs, rhs in
            let depths = (lhs.split(separator: "/").count, rhs.split(separator: "/").count)
            return depths.0 != depths.1 ? depths.0 < depths.1 : lhs < rhs
        }
    }

    init(skipProtected: Bool = false, accountHome: String? = nil) {
        self.skipProtected = skipProtected
        self.accountHome = accountHome
    }

    struct Collected {
        var files: [FileHit]
        var gitDirectories: [String]
        var skippedFolders: [String]
    }

    /// Hands over what the walk collected and empties the delegate. A
    /// walker thread stuck in a listing keeps the delegate alive, possibly
    /// forever; it shouldn't keep the scan's findings alive with it.
    func takeCollected() -> Collected {
        let skipped = skippedFolders
        skippedPaths.withLock { $0 = [] }
        return Collected(
            files: fileHits.withLock { hits in defer { hits = [] }; return hits },
            gitDirectories: repositories.withLock { paths in defer { paths = [] }; return paths },
            skippedFolders: skipped)
    }

    /// Protected subfolders of the folder at `path` to skip, by where they
    /// are relative to the account's home.
    private func protectedFolders(of path: String, _ entries: [DirectoryEntry]) -> [String] {
        guard skipProtected, let accountHome,
            let relative = PrivacyProtected.relative(path, to: accountHome)
        else { return [] }
        let names = PrivacyProtected.skipped(in: relative, entries: entries)
        if !names.isEmpty {
            let root = scanRoot.withLock { $0 } ?? path
            let prefix = path == root ? "" : String(path.dropFirst(root.count + 1)) + "/"
            skippedPaths.withLock { $0.append(contentsOf: names.map { prefix + $0 }) }
        }
        return names
    }

    func rootContext() -> Context {
        Context(parentRelative: nil, scope: Scope(), parent: .none)
    }

    func visit(_ dir: VisitedDirectory<Context>) -> Visit<Context, DirectoryMatch> {
        if dir.depth == 0 {
            scanRoot.withLock { $0 = dir.path }
            // Home's listing incomplete: the same rule as anywhere else,
            // nothing in it or under it is classified.
            var scope = Scope()
            if dir.isComplete {
                recordFiles(dir.entries, in: dir.path, scope: scope)
            } else {
                scope.claimed = true
            }
            return Visit(
                mark: nil,
                childContext: Context(
                    parentRelative: [], scope: scope,
                    parent: dir.isComplete ? ProjectFacts(entries: dir.entries) : .none),
                unreadable: protectedFolders(of: dir.path, dir.entries))
        }
        let context = dir.context
        if dir.name == ".git", dir.entries.contains(where: { $0.name == "worktrees" && $0.kind == .directory }) {
            repositories.withLock { $0.append(dir.path) }
        }
        // Inside node_modules, a cache or a .git folder: nothing to classify.
        let relative = context.parentRelative.map { $0 + [dir.name] }
        if context.scope.claimed {
            return Visit(
                mark: nil, childContext: context, unreadable: protectedFolders(of: dir.path, dir.entries))
        }
        // Part of the listing is missing: what's absent (a `.git` file, a
        // marker, a newer file) can't count as evidence, so neither this
        // folder nor anything inside it is classified. The cleaner, which
        // lists strictly, refuses anything here too.
        if !dir.isComplete {
            var inner = context.scope
            inner.claimed = true
            return Visit(
                mark: nil,
                childContext: Context(
                    parentRelative: relative.flatMap { $0.count < RuleCatalog.maxDepth ? $0 : nil },
                    scope: inner, parent: .none),
                excluded: Classifier.excludedChildren(of: relative),
                unreadable: protectedFolders(of: dir.path, dir.entries))
        }
        let (match, inner) = Classifier.classify(DirectoryFacts(
            path: dir.path, name: dir.name, relative: relative, scope: context.scope,
            parent: context.parent, entries: dir.entries))
        if !inner.claimed {
            recordFiles(dir.entries, in: dir.path, scope: inner)
        }
        let childContext = Context(
            parentRelative: relative.flatMap { $0.count < RuleCatalog.maxDepth ? $0 : nil },
            scope: inner,
            parent: inner.claimed ? .none : ProjectFacts(entries: dir.entries, of: match, at: dir.path))
        return Visit(
            mark: match, childContext: childContext,
            excluded: Classifier.excludedChildren(of: relative),
            unreadable: protectedFolders(of: dir.path, dir.entries))
    }

    private func recordFiles(_ entries: [DirectoryEntry], in path: String, scope: Scope) {
        for entry in entries where entry.kind == .file && entry.allocatedSize >= Classifier.installerBytes {
            if let match = Classifier.classifyFile(entry, in: scope) {
                let hit = FileHit(path: path + "/" + entry.name, entry: entry, match: match)
                fileHits.withLock { $0.append(hit) }
            }
        }
    }
}
