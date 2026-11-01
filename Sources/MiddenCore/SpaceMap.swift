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
/// Findings are exempt: a finding's node, and every folder on the way to
/// it, is always kept, so the app can show and select each finding. Only
/// the finding's own node carries its id. Wherever a node has children,
/// they add up exactly to its size.
enum SpaceMap {
    static let maxChildren = 40
    /// Levels below the root.
    static let maxDepth = 10
    /// Children smaller than this share of the root are merged into "Other"
    /// (or smaller than the walk's floor, WalkDefaults.mapFloor, if bigger).
    static let minimumShare = 0.0005

    /// - Parameter aliases: other paths of a finding, by finding id: the other
    ///   names of a hard-linked file. The walk counts such a file under
    ///   whichever name it met first, which may not be the finding's path.
    static func build(
        _ records: [SpaceRecord], root: String, findings: [Finding], aliases: [String: [String]] = [:],
        floor: Int64, maxChildren: Int = maxChildren, maxDepth: Int = maxDepth
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
        let named = findings.flatMap { finding in
            ([finding.path] + (aliases[finding.id] ?? [])).map { ($0, finding.id) }
        }
        let findingIDs = Dictionary(
            named.filter { $0.0.hasPrefix(root + "/") }, uniquingKeysWith: { first, _ in first })
        // Folders on the way from the root to a finding.
        var towardFindings = Set<String>()
        for path in findingIDs.keys {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix(root + "/"), towardFindings.insert(folder).inserted {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }

        func node(_ record: SpaceRecord, depth: Int) -> SpaceNode {
            let all = (children[record.path] ?? []).sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
            let kept = all.filter { findingIDs[$0.path] != nil || towardFindings.contains($0.path) }
            let others = depth < maxDepth
                ? all.filter { $0.bytes >= threshold && findingIDs[$0.path] == nil && !towardFindings.contains($0.path) }
                    .prefix(max(maxChildren - kept.count, 0))
                : []
            let shown = (kept + others).sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
            var nodes = shown.map { node($0, depth: depth + 1) }
            let rest = record.bytes - shown.reduce(0) { $0 + $1.bytes }
            if !shown.isEmpty, rest > 0 {
                let count = max(record.entries - shown.count, 1)
                nodes.append(SpaceNode(
                    name: "Other (\(count) \(count == 1 ? "item" : "items"))", path: record.path + "/(other)",
                    bytes: rest, isDirectory: false, isOther: true))
            }
            return SpaceNode(
                name: (record.path as NSString).lastPathComponent, path: record.path, bytes: record.bytes,
                isDirectory: record.isDirectory, findingID: findingIDs[record.path], children: nodes)
        }
        return node(top, depth: 0)
    }
}
