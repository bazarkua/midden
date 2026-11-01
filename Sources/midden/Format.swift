import Foundation
import MiddenCore

enum Format {
    /// Decimal units, like Finder: 1 GB is 10^9 bytes.
    static func bytes(_ count: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        guard count >= 1_000 else { return count == 1 ? "1 byte" : "\(count) bytes" }
        var value = Double(count) / 1_000
        var unit = 0
        while value >= 999.95, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        return unit == 0
            ? "\(Int(value.rounded())) KB"
            : String(format: "%.1f %@", value, units[unit])
    }

    /// Parses "50MB", "1.5 GB", "200k" or a plain number of bytes.
    static func parseBytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "B": 1, "K": 1e3, "KB": 1e3, "M": 1e6, "MB": 1e6, "G": 1e9, "GB": 1e9,
            "T": 1e12, "TB": 1e12,
        ]
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64(number * multiplier)
    }

    /// The user's home folder as the scanner reports paths: canonical.
    static let userHome: String = {
        let home = NSHomeDirectory()
        guard let resolved = realpath(home, nil) else { return home }
        defer { free(resolved) }
        return String(cString: resolved)
    }()

    /// "45 s" or "3 min".
    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(Int(seconds.rounded()), 1)) s" : "\(Int((seconds / 60).rounded())) min"
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func count(_ number: Int64) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// Replaces the home folder with ~.
    static func path(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Word-wraps text to `width` columns, indenting every line.
    static func wrap(_ text: String, width: Int, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > width - indent {
                lines.append(pad + line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(pad + line) }
        return lines.joined(separator: "\n")
    }

    static func describe(_ action: CleanAction, home: String) -> String {
        switch action {
        case .removeDirectory: "delete the folder"
        case .removeContents: "delete what the explanation says inside the folder, keeping the folder"
        case .removeFile: "delete the file"
        case .run(let arguments):
            "run `" + arguments.map { argument in
                let short = path(argument, home: home)
                return short.contains(" ") ? "'\(short)'" : short
            }.joined(separator: " ") + "`"
        case .moveToTrash: "move it to the Trash"
        case .manual(let instructions): instructions
        }
    }
}

/// Output helpers. Colors only when the stream is a terminal.
enum Terminal {
    static let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
    static let stderrIsTTY = isatty(STDERR_FILENO) == 1
    static let stdinIsTTY = isatty(STDIN_FILENO) == 1

    static var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 { return Int(size.ws_col) }
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 { return Int(size.ws_col) }
        return 100
    }

    static func print(_ text: String = "") {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String, newline: Bool = true) {
        FileHandle.standardError.write(Data((text + (newline ? "\n" : "")).utf8))
    }

    enum Color: String {
        case green = "32", yellow = "33", blue = "34", red = "31", bold = "1", dim = "2"
    }

    static func paint(_ text: String, _ color: Color, enabled: Bool = stdoutIsTTY) -> String {
        enabled ? "\u{1B}[\(color.rawValue)m\(text)\u{1B}[0m" : text
    }

    static func tag(_ safety: Safety, enabled: Bool = stdoutIsTTY) -> String {
        switch safety {
        case .safe: paint("SAFE  ", .green, enabled: enabled)
        case .review: paint("REVIEW", .yellow, enabled: enabled)
        case .info: paint("INFO  ", .blue, enabled: enabled)
        }
    }
}
