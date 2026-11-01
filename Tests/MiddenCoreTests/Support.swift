import Foundation
@testable import MiddenCore

/// A temporary directory with a canonical path (on macOS /var is a symlink
/// to /private/var, and the scanner and cleaner work on resolved paths).
/// Deleted when the value is released.
final class TempDir {
    let path: String

    init(_ label: String = "midden") throws {
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
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "Test"
    environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
    environment["GIT_COMMITTER_NAME"] = "Test"
    environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
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
