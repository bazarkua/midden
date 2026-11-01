import Foundation
import Testing
@testable import MiddenCore

/// The `midden` command-line tool built from these sources, when it's at
/// least as new as every source file. `swift test` doesn't build it, so the
/// tests below run only after `swift build`, and skip otherwise rather than
/// test an old binary.
private enum BuiltCLI {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    static let path: String? = {
        let binary = packageRoot + "/.build/debug/midden"
        guard let built = modified(binary) else { return nil }
        let sources = FileManager.default.enumerator(atPath: packageRoot + "/Sources")?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        let newest = sources.compactMap { modified(packageRoot + "/Sources/" + $0) }.max() ?? .distantFuture
        return built >= newest ? binary : nil
    }()

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

extension JSONDecoder {
    /// Decodes what `midden --json` prints (ISO 8601 dates).
    static var midden: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Runs the CLI with the given environment additions; returns status and stdout.
private func midden(_ arguments: [String], adding variables: [String: String]) throws -> (Int32, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try #require(BuiltCLI.path))
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for (name, value) in Hermetic.gitEnvironment {
        environment[name] = value
    }
    environment.merge(variables) { $1 }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

@Suite(.enabled(if: BuiltCLI.path != nil, "Build the CLI first: swift build"))
struct CLITests {
    /// Started from a shell or a git hook that exported GIT_DIR and
    /// GIT_WORK_TREE for another, clean repository, the real tool must
    /// still see that a worktree has unsaved work, in the scan and when
    /// asked to clean it.
    @Test func inheritedGitVariablesDontHideAWorktreesChanges() throws {
        let home = try TempDir("home")
        let other = try makeRepository(home, "other")
        let repository = try makeRepository(home)
        let worktree = try addWorktree(home, repository: repository, branch: "feature")
        try home.write("worktrees/feature/unsaved.txt", text: "draft")
        let inherited = ["GIT_DIR": other + "/.git", "GIT_WORK_TREE": other]

        let (scanStatus, scanOutput) = try midden(
            ["scan", "--json", "--home", home.path, "--min-size", "0"], adding: inherited)
        #expect(scanStatus == 0)
        let report = try JSONDecoder.midden.decode(ScanReport.self, from: scanOutput)
        let finding = try #require(report.findings.first { $0.path == worktree })
        #expect(finding.safety == .info)
        #expect(finding.checks.first { $0.id == "uncommitted" }?.passed == false)

        let (cleanStatus, cleanOutput) = try midden(
            ["clean", "--yes", "--json", "--home", home.path, worktree], adding: inherited)
        #expect(cleanStatus != 0)
        let summary = try JSONDecoder.midden.decode(CleanSummary.self, from: cleanOutput)
        #expect(summary.results.first?.ok == false)
        #expect(FileManager.default.fileExists(atPath: home.path("worktrees/feature/unsaved.txt")))
    }
}
