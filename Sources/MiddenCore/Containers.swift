import Foundation

/// Accounting for containers: folders a rule matches that hold folders
/// other rules match, and folders a rule reports without claiming what's
/// in them (Downloads). The findings inside one partition it, folders and
/// files alike, so its own finding is only its remainder: its total minus
/// the totals of the outermost findings inside it. Nothing is counted
/// twice.
enum Containers {
    /// A folder the walk sized, as the accounting needs it.
    struct Sized {
        var path: String
        var total: Int64
        var isContainer: Bool
        /// Immediate children and their sizes, for the breakdown.
        var children: [SizedDirectory<DirectoryMatch>.Child] = []
    }

    /// For each container, its total minus what findings inside it cover,
    /// and its children's sizes with those findings taken out.
    static func remainders(_ folders: [Sized]) -> [String: (bytes: Int64, children: [SizedDirectory<DirectoryMatch>.Child])] {
        let containers = Dictionary(
            folders.filter(\.isContainer).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard !containers.isEmpty else { return [:] }
        var covered: [String: Int64] = [:]
        var coveredChildren: [String: [String: Int64]] = [:]
        for folder in folders {
            // The innermost container above this folder, if any: the
            // folder's total belongs to it, not to containers further up.
            var parent = (folder.path as NSString).deletingLastPathComponent
            var childName = (folder.path as NSString).lastPathComponent
            while parent.count > 1, containers[parent] == nil {
                childName = (parent as NSString).lastPathComponent
                parent = (parent as NSString).deletingLastPathComponent
            }
            guard containers[parent] != nil else { continue }
            covered[parent, default: 0] += folder.total
            coveredChildren[parent, default: [:]][childName, default: 0] += folder.total
        }
        var result: [String: (bytes: Int64, children: [SizedDirectory<DirectoryMatch>.Child])] = [:]
        for (path, container) in containers {
            let inside = coveredChildren[path] ?? [:]
            let children = container.children.compactMap { child -> SizedDirectory<DirectoryMatch>.Child? in
                var child = child
                child.bytes -= inside[child.name] ?? 0
                return child.bytes > 0 ? child : nil
            }
            result[path] = (max(container.total - (covered[path] ?? 0), 0), children)
        }
        return result
    }

    /// A container's remainder measured now, for the cleaner: the folder's
    /// total minus the outermost findings the classifier finds inside it.
    /// - Parameters: scope, parent: what the container itself inherited.
    static func remainder(of path: String, relative: [String], scope: Scope, parent: ProjectFacts) -> Int64? {
        let delegate = NestedRules(relative: relative, scope: scope, parent: parent)
        guard let walk = try? Walker(root: path, delegate: delegate).run() else { return nil }
        let folders = walk.marked.compactMap { folder -> Sized? in
            guard let match = folder.mark else { return nil }
            var isContainer = false
            if case .rule(let rule) = match { isContainer = rule.isContainer }
            return Sized(path: folder.path, total: folder.total, isContainer: isContainer)
        } + [Sized(path: path, total: walk.totalBytes, isContainer: true)]
        return remainders(folders)[path]?.bytes
    }
}

/// Classifies inside one container the way the scanner does, marking the
/// rule folders it finds.
private struct NestedRules: WalkDelegate {
    struct Context: Sendable {
        var relative: [String]?
        var scope: Scope
        var parent: ProjectFacts
    }

    var relative: [String]
    var scope: Scope
    var parent: ProjectFacts

    func rootContext() -> Context {
        Context(relative: relative, scope: scope, parent: parent)
    }

    func visit(_ dir: VisitedDirectory<Context>) -> Visit<Context, DirectoryMatch> {
        let context = dir.context
        // The root is the container itself: classified again only for the
        // scope its contents inherit.
        if dir.depth == 0 {
            let (match, inner) = Classifier.classify(DirectoryFacts(
                path: dir.path, name: dir.name, relative: context.relative, scope: context.scope,
                parent: context.parent, entries: dir.entries))
            return Visit(
                mark: nil,
                childContext: Context(
                    relative: context.relative, scope: inner, parent: ProjectFacts(entries: dir.entries, of: match, at: dir.path)))
        }
        let relative = context.relative.map { $0 + [dir.name] }
        guard !context.scope.claimed, dir.isComplete else {
            var inner = context.scope
            inner.claimed = true
            return Visit(mark: nil, childContext: Context(relative: nil, scope: inner, parent: .none))
        }
        let (match, inner) = Classifier.classify(DirectoryFacts(
            path: dir.path, name: dir.name,
            relative: relative.flatMap { $0.count <= RuleCatalog.maxDepth ? $0 : nil },
            scope: context.scope, parent: context.parent, entries: dir.entries))
        return Visit(
            mark: match,
            childContext: Context(
                relative: relative.flatMap { $0.count < RuleCatalog.maxDepth ? $0 : nil },
                scope: inner, parent: inner.claimed ? .none : ProjectFacts(entries: dir.entries, of: match, at: dir.path)))
    }
}
