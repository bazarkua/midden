import Foundation

/// A file or folder the walk remembered for the space map: everything at or
/// above the floor. A folder's size includes everything inside it, so the
/// parent of a remembered item is always remembered too, up to the root.
struct SpaceRecord: Sendable, Hashable {
    var path: String
    var bytes: Int64
    var isDirectory: Bool
    /// Entries directly inside a folder, to say how many items "Other" holds.
    var entries: Int
}

/// Builds the home folder's size tree for the space map from what the walk
/// remembered, then prunes it to something a treemap can draw:
/// - children smaller than max(0.05% of the root, the floor) are merged into
///   one "Other (N items)" node per parent;
/// - at most `maxChildren` children per node, the rest merged the same way;
/// - at most `maxDepth` levels below the root.
/// Wherever a node has children, they add up exactly to its size.
enum SpaceMap {
    static let maxChildren = 40
    /// Levels below the root.
    static let maxDepth = 10
    /// Children smaller than this share of the root are merged into "Other"
    /// (or smaller than the walk's floor, WalkDefaults.mapFloor, if bigger).
    static let minimumShare = 0.0005

    static func build(
        _ records: [SpaceRecord], root: String, findings: [Finding], floor: Int64,
        maxChildren: Int = maxChildren, maxDepth: Int = maxDepth
    ) -> SpaceNode? {
        var byPath: [String: SpaceRecord] = [:]
        var children: [String: [SpaceRecord]] = [:]
        for record in records {
            byPath[record.path] = record
            guard record.path != root else { continue }
            let parent = (record.path as NSString).deletingLastPathComponent
            children[parent, default: []].append(record)
        }
        guard let top = byPath[root] else { return nil }
        let threshold = max(Int64(Double(top.bytes) * minimumShare), floor)
        // Folder and file findings by path; nodes inside one inherit its id.
        let findingIDs = Dictionary(
            findings.filter { $0.path.hasPrefix(root + "/") }.map { ($0.path, $0.id) },
            uniquingKeysWith: { first, _ in first })

        func node(_ record: SpaceRecord, depth: Int, inherited: String?) -> SpaceNode {
            let findingID = findingIDs[record.path] ?? inherited
            let candidates = (children[record.path] ?? [])
                .filter { $0.bytes >= threshold }
                .sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
            let kept = depth < maxDepth ? Array(candidates.prefix(maxChildren)) : []
            var nodes = kept.map { node($0, depth: depth + 1, inherited: findingID) }
            let rest = record.bytes - kept.reduce(0) { $0 + $1.bytes }
            if !kept.isEmpty, rest > 0 {
                let count = max(record.entries - kept.count, 1)
                nodes.append(SpaceNode(
                    name: "Other (\(count) \(count == 1 ? "item" : "items"))", path: record.path,
                    bytes: rest, isDirectory: false, findingID: findingID, children: []))
            }
            return SpaceNode(
                name: record.path == root ? (root as NSString).lastPathComponent : (record.path as NSString).lastPathComponent,
                path: record.path, bytes: record.bytes, isDirectory: record.isDirectory,
                findingID: findingID, children: nodes)
        }
        return node(top, depth: 0, inherited: nil)
    }
}
