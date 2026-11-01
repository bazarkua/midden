import Foundation
@testable import MiddenCore

/// Every git command the tests cause, directly or through Midden, ignores
/// the machine's git configuration. A developer's or CI runner's global
/// config can change what git does: with core.fsmonitor=true, for one, a
/// commit in a worktree starts a file-watcher daemon that keeps running, and
/// Midden would see the worktree as in use. Variables that point git at
/// another repository are removed too.
enum Hermetic {
    static let gitEnvironment: [String: String?] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": nil,
        "GIT_CONFIG_PARAMETERS": nil,
        "GIT_CONFIG_COUNT": nil,
        "GIT_DIR": nil,
        "GIT_WORK_TREE": nil,
        "GIT_INDEX_FILE": nil,
        "GIT_OBJECT_DIRECTORY": nil,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": nil,
        "GIT_COMMON_DIR": nil,
        "GIT_NAMESPACE": nil,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    ]

    /// Makes Midden's own commands hermetic too. Runs once.
    static let applied: Void = {
        Command.environmentOverrides.withLock { $0.merge(gitEnvironment) { _, new in new } }
    }()
}

/// A temporary directory with a canonical path (on macOS /var is a symlink
/// to /private/var, and the scanner and cleaner work on resolved paths).
/// Deleted when the value is released.
final class TempDir {
    let path: String

    init(_ label: String = "midden") throws {
        Hermetic.applied
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else {
            throw POSIXError(errno)
        }
        path = String(cString: resolved)
        free(resolved)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    var url: URL { URL(fileURLWithPath: path) }

    func path(_ relative: String) -> String {
        relative.isEmpty ? path : path + "/" + relative
    }

    @discardableResult
    func mkdir(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// Writes `bytes` bytes of non-zero data (so APFS can't elide them).
    @discardableResult
    func write(_ relative: String, bytes: Int = 0, text: String? = nil) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let data = text.map { Data($0.utf8) } ?? Data(repeating: 0x5A, count: bytes)
        guard FileManager.default.createFile(atPath: full, contents: data) else {
            throw POSIXError(.EIO)
        }
        return full
    }

    /// Sets the modification time of a file or folder.
    func touch(_ relative: String, daysAgo: Double) throws {
        let date = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: path(relative))
    }
}

/// Runs a command and returns trimmed stdout; throws if it fails.
@discardableResult
func sh(_ arguments: [String], in directory: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    Hermetic.applied
    var environment = ProcessInfo.processInfo.environment
    for (name, value) in Hermetic.gitEnvironment {
        environment[name] = value
    }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ShellError(command: arguments.joined(separator: " "), status: process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ShellError: Error, CustomStringConvertible {
    var command: String
    var status: Int32
    var description: String { "`\(command)` exited with \(status)" }
}
