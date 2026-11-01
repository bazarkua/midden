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

    private let fileHits = Mutex<[FileHit]>([])
    private let repositories = Mutex<[String]>([])

    var files: [FileHit] { fileHits.withLock { $0 } }

    /// `.git` folders that list linked worktrees, wherever the walk saw them.
    var gitDirectories: [String] { repositories.withLock { $0 } }

    func rootContext() -> Context {
        Context(parentRelative: nil, scope: Scope(), parent: .none)
    }

    func visit(_ dir: VisitedDirectory<Context>) -> Visit<Context, DirectoryMatch> {
        if dir.depth == 0 {
            recordFiles(dir.entries, in: dir.path, scope: Scope())
            return Visit(
                mark: nil,
                childContext: Context(
                    parentRelative: [], scope: Scope(), parent: ProjectFacts(entries: dir.entries)))
        }
        let context = dir.context
        if dir.name == ".git", dir.entries.contains(where: { $0.name == "worktrees" && $0.kind == .directory }) {
            repositories.withLock { $0.append(dir.path) }
        }
        // Inside node_modules, a cache or a .git folder: nothing to classify.
        if context.scope.claimed {
            return Visit(mark: nil, childContext: context)
        }
        let relative = context.parentRelative.map { $0 + [dir.name] }
        let (match, inner) = Classifier.classify(DirectoryFacts(
            path: dir.path, name: dir.name, relative: relative, scope: context.scope,
            parent: context.parent, entries: dir.entries))
        if !inner.claimed {
            recordFiles(dir.entries, in: dir.path, scope: inner)
        }
        let childContext = Context(
            parentRelative: relative.flatMap { $0.count < RuleCatalog.maxDepth ? $0 : nil },
            scope: inner,
            parent: inner.claimed ? .none : ProjectFacts(entries: dir.entries))
        return Visit(
            mark: match, childContext: childContext,
            excluded: Classifier.excludedChildren(of: relative))
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
