import Foundation
import Testing
@testable import MiddenCore

// Commands Midden tells people to run must exist in the version of the
// tool they were checked against. The help text below is a fixture taken
// from that version; update both together.

@Suite struct CommandTextTests {
    /// `hf version` printed 1.5.0; this is `hf cache --help` from it.
    static let hfVersion = "1.5.0"
    static let hfCacheHelp = """
        Usage: hf cache [OPTIONS] COMMAND [ARGS]...

          Manage local cache directory.

        Options:
          -h, --help  Show this message and exit.

        Main commands:
          ls      List cached repositories or revisions.
          prune   Remove detached revisions from the cache.
          rm      Remove cached repositories or revisions.
          verify  Verify checksums for a single repo revision from cache or a local
                  directory.

        Examples
          $ hf cache ls
          $ hf cache prune
          $ hf cache rm model/gpt2
          $ hf cache verify gpt2
        """

    /// Subcommands under "Main commands:" in a click-style help text.
    static func subcommands(_ help: String) -> Set<String> {
        var inSection = false
        var names: Set<String> = []
        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Main commands:") {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            // A subcommand line is indented by two spaces; continuations more.
            if line.hasPrefix("  "), !line.hasPrefix("   "), let name = line.split(separator: " ").first {
                names.insert(String(name))
            }
        }
        return names
    }

    @Test func huggingFaceInstructionsUseTheCurrentCLI() throws {
        let match = try #require(RuleCatalog.match([".cache", "huggingface"]))
        guard case .manual(let instructions) = match.rule.action else {
            Issue.record("Hugging Face models must stay manual")
            return
        }
        #expect(!instructions.contains("huggingface-cli"))
        #expect(instructions.contains(Self.hfVersion.split(separator: ".").prefix(2).joined(separator: ".")))
        let available = Self.subcommands(Self.hfCacheHelp)
        #expect(available == ["ls", "prune", "rm", "verify"])
        // Every `hf cache <command>` the text names exists in that version.
        let named = instructions.components(separatedBy: "`hf cache ").dropFirst().compactMap {
            $0.split(whereSeparator: { $0 == " " || $0 == "`" }).first.map(String.init)
        }
        #expect(!named.isEmpty)
        for command in named {
            #expect(available.contains(command), "hf cache \(command)")
        }
    }
}
