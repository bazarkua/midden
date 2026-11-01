import Foundation
import MiddenCore
import Synchronization

enum CLI {
    static let version = "0.1.0"

    static let usage = """
        midden \(version): finds what's safe to delete in your home folder and explains why.

        Usage:
          midden scan [--json] [--home PATH] [--min-size SIZE]
          midden clean [--yes] [--json] [--home PATH] ID...
          midden --help | --version

        scan     Lists what takes space and what deleting it would cost.
                 --json        Print the full report as JSON.
                 --home PATH   Scan another folder instead of your home folder.
                 --min-size    Leave out findings smaller than this (default 50MB).

        clean    Deletes the findings with the given IDs (the paths `scan` prints,
                 or sim:<UDID> for simulators). Every ID is checked again from
                 scratch first; Midden refuses anything that no longer qualifies.
                 --yes         Don't ask for confirmation.
                 --json        Print the result as JSON.
                 --home PATH   The home folder the IDs belong to.

        Sizes are bytes allocated on disk, in decimal units like Finder (1 GB = 10^9 bytes).
        """

    struct UsageError: Error {
        var message: String
    }

    /// Returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first else {
                Terminal.print(usage)
                return 0
            }
            let rest = Array(arguments.dropFirst())
            switch command {
            case "-h", "--help", "help":
                Terminal.print(usage)
                return 0
            case "-v", "--version", "version":
                Terminal.print("midden \(version)")
                return 0
            case "scan":
                return try await scan(rest)
            case "clean":
                return try await clean(rest)
            default:
                throw UsageError(message: "Unknown command “\(command)”.")
            }
        } catch let error as UsageError {
            Terminal.error("midden: \(error.message)\nRun `midden --help` for usage.")
            return 2
        } catch {
            Terminal.error("midden: \(error.localizedDescription)")
            return 1
        }
    }

    /// Splits flags from positional arguments.
    struct Arguments {
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var positional: [String] = []

        init(_ arguments: [String], flags allowedFlags: Set<String>, options: Set<String>) throws {
            var iterator = arguments.makeIterator()
            var onlyPositional = false
            while let argument = iterator.next() {
                if onlyPositional || !argument.hasPrefix("-") || argument == "-" {
                    positional.append(argument)
                } else if argument == "--" {
                    onlyPositional = true
                } else if allowedFlags.contains(argument) {
                    flags.insert(argument)
                } else if let equals = argument.firstIndex(of: "="),
                    options.contains(String(argument[..<equals]))
                {
                    values[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
                } else if options.contains(argument) {
                    guard let value = iterator.next() else {
                        throw UsageError(message: "\(argument) needs a value.")
                    }
                    values[argument] = value
                } else {
                    throw UsageError(message: "Unknown option \(argument).")
                }
            }
        }
    }

    static func homeURL(_ arguments: Arguments) -> URL {
        guard let path = arguments.values["--home"] else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: scan

    static func scan(_ raw: [String]) async throws -> Int32 {
        let arguments = try Arguments(raw, flags: ["--json"], options: ["--home", "--min-size"])
        guard arguments.positional.isEmpty else {
            throw UsageError(message: "scan takes no arguments, got “\(arguments.positional[0])”.")
        }
        var options = ScanOptions(home: homeURL(arguments))
        if let text = arguments.values["--min-size"] {
            guard let bytes = Format.parseBytes(text) else {
                throw UsageError(message: "Can't read the size “\(text)”. Try 50MB or 1GB.")
            }
            options.minimumBytes = bytes
        }

        let progress = ProgressLine(enabled: Terminal.stderrIsTTY, home: options.home.path)
        let report = try await Scanner(options: options).scan { progress.update($0) }
        progress.clear()

        if arguments.flags.contains("--json") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            Terminal.print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            printReport(report)
        }
        return 0
    }

    static func printReport(_ report: ScanReport) {
        let home = Format.userHome
        let width = min(Terminal.width, 110)
        let indent = 18
        Terminal.print(
            "Scanned \(Format.path(report.home, home: home)) in \(String(format: "%.1f", report.duration)) s: "
                + "\(Format.count(report.itemsScanned)) items, \(Format.bytes(report.bytesScanned)) on disk.")
        Terminal.print(
            "Disk: \(Format.bytes(report.disk.free)) free of \(Format.bytes(report.disk.total)).")
        if report.needsFullDiskAccess || report.unreadableCount > 0 {
            var note = "\(report.unreadableCount) folders couldn't be read."
            if report.needsFullDiskAccess {
                note += " Give your terminal Full Disk Access (System Settings → Privacy & Security) to see the Trash, Mail and device backups."
            }
            Terminal.print(Terminal.paint(note, .dim))
        }

        for category in Category.allCases {
            let findings = report.findings.filter { $0.category == category }
            guard !findings.isEmpty else { continue }
            let total = findings.reduce(0) { $0 + $1.bytes }
            Terminal.print()
            Terminal.print(
                Terminal.paint(category.title, .bold) + "  "
                    + Terminal.paint("\(Format.bytes(total)) in \(Format.items(findings.count))", .dim))
            for finding in findings {
                let size = Format.bytes(finding.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
                Terminal.print("  \(Terminal.tag(finding.safety))  \(size) \(finding.title)")
                let pad = String(repeating: " ", count: indent)
                Terminal.print(pad + Terminal.paint(Format.path(finding.path, home: home), .dim))
                if finding.id != finding.path {
                    Terminal.print(pad + Terminal.paint("id: \(finding.id)", .dim))
                }
                Terminal.print(Format.wrap(finding.explanation, width: width, indent: indent))
                for check in finding.checks where !check.passed {
                    Terminal.print(Format.wrap("✗ \(check.title): \(check.detail)", width: width, indent: indent))
                }
                if case .manual(let instructions) = finding.action {
                    Terminal.print(Format.wrap("→ \(instructions)", width: width, indent: indent))
                }
            }
        }

        Terminal.print()
        let safe = report.findings.filter { $0.safety == .safe && $0.action.isAutomatic }
        let review = report.findings.filter { $0.safety == .review && $0.action.isAutomatic }
        Terminal.print(
            "\(Terminal.paint("Safe to clean:", .green)) \(Format.bytes(report.reclaimable(.safe))) in \(Format.items(safe.count)). "
                + "\(Terminal.paint("Worth a look:", .yellow)) \(Format.bytes(report.reclaimable(.review))) in \(Format.items(review.count)).")
        if !safe.isEmpty {
            Terminal.print("Clean an item with `midden clean <path>`; Midden checks it again before deleting.")
        }
    }

    // MARK: clean

    static func clean(_ raw: [String]) async throws -> Int32 {
        let arguments = try Arguments(raw, flags: ["--yes", "-y", "--json"], options: ["--home"])
        guard !arguments.positional.isEmpty else {
            throw UsageError(message: "clean needs at least one ID (a path from `midden scan`).")
        }
        let homeURL = homeURL(arguments)
        let home = Format.userHome
        // Paths printed as ~/... are accepted as typed.
        let ids = arguments.positional.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        let json = arguments.flags.contains("--json")
        // With --json, stdout carries only the JSON; messages go to stderr.
        let say: @Sendable (String) -> Void = { text in
            if json { Terminal.error(text) } else { Terminal.print(text) }
        }
        let color = json ? Terminal.stderrIsTTY : Terminal.stdoutIsTTY

        let cleaner = Cleaner(home: homeURL)
        let plans = await cleaner.plan(ids)
        for plan in plans {
            let shown = plan.finding.map { Format.path($0.path, home: home) } ?? Format.path(plan.id, home: home)
            if let finding = plan.finding, plan.isApproved {
                say("  \(Terminal.tag(finding.safety, enabled: color))  \(Format.bytes(finding.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(finding.title)")
                say("                    \(shown): will \(Format.describe(finding.action, home: home))")
            } else {
                say("  \(Terminal.paint("REFUSED", .red, enabled: color)) \(shown)")
                say(Format.wrap(plan.refusal ?? "Not recognized.", width: min(Terminal.width, 110), indent: 10))
            }
        }
        let approved = plans.filter(\.isApproved)
        let refused = plans.filter { !$0.isApproved }.map {
            CleanResult(id: $0.id, ok: false, message: $0.refusal ?? "Not recognized.")
        }
        guard !approved.isEmpty else {
            say("Nothing to clean.")
            if json { printJSON(CleanSummary(results: refused, freeBefore: 0, freeAfter: 0)) }
            return 1
        }

        if !arguments.flags.contains("--yes") && !arguments.flags.contains("-y") {
            guard Terminal.stdinIsTTY else {
                throw UsageError(message: "Pass --yes to clean without a terminal to confirm in.")
            }
            let total = approved.reduce(0) { $0 + ($1.finding?.bytes ?? 0) }
            Terminal.error(
                "Delete \(approved.count) \(approved.count == 1 ? "item" : "items") (\(Format.bytes(total)))? [y/N] ",
                newline: false)
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                say("Nothing deleted.")
                return 1
            }
        }

        let summary = await cleaner.clean(approved.map(\.id)) { result in
            let shown = Format.path(result.id, home: home)
            if result.ok {
                say("  \(Terminal.paint("✓", .green, enabled: color)) \(shown)")
            } else {
                say("  \(Terminal.paint("✗", .red, enabled: color)) \(shown): \(result.message ?? "failed")")
            }
        }
        let freed = summary.freeAfter - summary.freeBefore
        say("Free space: \(Format.bytes(summary.freeBefore)) → \(Format.bytes(summary.freeAfter)) (\(freed >= 0 ? "+" : "−")\(Format.bytes(abs(freed)))).")
        if json {
            // Every id, in the order given.
            let cleaned = Dictionary(summary.results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let refusedByID = Dictionary(refused.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            printJSON(CleanSummary(
                results: plans.compactMap { cleaned[$0.id] ?? refusedByID[$0.id] },
                freeBefore: summary.freeBefore, freeAfter: summary.freeAfter))
        }
        return refused.isEmpty && summary.results.allSatisfy(\.ok) ? 0 : 1
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            Terminal.print(String(decoding: data, as: UTF8.self))
        }
    }
}

/// The "Scanning…" line on stderr, redrawn in place.
final class ProgressLine: Sendable {
    let enabled: Bool
    let home: String
    private let shown = Mutex(false)

    init(enabled: Bool, home: String) {
        self.enabled = enabled
        self.home = home
    }

    func update(_ progress: ScanProgress) {
        guard enabled else { return }
        let width = Terminal.width
        var line = "Scanning… \(Format.count(progress.items)) items, \(Format.bytes(progress.bytes))  "
            + Format.path(progress.currentPath, home: home)
        if line.count > width - 1 { line = String(line.prefix(width - 2)) + "…" }
        shown.withLock { shown in
            Terminal.error("\r\u{1B}[K" + line, newline: false)
            shown = true
        }
    }

    func clear() {
        shown.withLock { shown in
            if shown { Terminal.error("\r\u{1B}[K", newline: false) }
            shown = false
        }
    }
}
