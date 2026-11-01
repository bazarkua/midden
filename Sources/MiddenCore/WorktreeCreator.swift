import Foundation

/// The AI coding tool that made a worktree, when its path shows it.
struct WorktreeCreator: Sendable, Hashable {
    var tool: String
    /// Why Midden thinks so, for the explanation.
    var evidence: String

    /// Only locations verified on a real Mac; anything else is unattributed.
    static func identify(_ path: String, home: String) -> WorktreeCreator? {
        let name = (path as NSString).lastPathComponent
        if path.contains("/.claude/worktrees/") {
            return WorktreeCreator(
                tool: "Claude Code", evidence: "it's in a .claude/worktrees folder, where Claude Code puts the worktrees it creates")
        }
        if path.hasPrefix("/private/tmp/claude-") {
            let folder = path.split(separator: "/").prefix(3).joined(separator: "/")
            return WorktreeCreator(tool: "Claude Code", evidence: "it's in Claude Code's temporary folder /\(folder)")
        }
        if path.hasPrefix(home + "/.codex/worktrees/") {
            return WorktreeCreator(tool: "Codex", evidence: "it's in ~/.codex/worktrees, where Codex keeps its worktrees")
        }
        if path.hasPrefix("/private/tmp/codex-") {
            let folder = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? name
            return WorktreeCreator(tool: "Codex", evidence: "its folder in /private/tmp is named “\(folder)”")
        }
        if path.hasPrefix(home + "/.cursor/worktrees/") {
            return WorktreeCreator(tool: "Cursor", evidence: "it's in ~/.cursor/worktrees, where Cursor keeps its agents' worktrees")
        }
        return nil
    }
}
