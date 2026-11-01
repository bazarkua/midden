import Foundation

/// Which of the user's programs use a folder: run from it, work in it, or
/// name it in their arguments (a browser started with a profile inside it,
/// a download writing into it, a script run from a package cache while the
/// shell's working directory is elsewhere). Read in-process like
/// `ProcessDirectories`. A check that can't run never passes: if any of the
/// user's processes can't be read completely, `failure` says so and no
/// folder counts as unused.
struct ProcessUsage: Sendable {
    struct Process: Sendable, Hashable {
        var pid: Int32
        var command: String
        var directory: String
        var executable: String
        var arguments: [String]

        /// What to tell the user to quit: the outermost app bundle the
        /// program runs from ("Spotify" for its helpers), else the
        /// program's file name. The kernel's command name is cut at 16
        /// bytes ("Spotify Helper (").
        var displayName: String {
            let components = executable.split(separator: "/")
            if let app = components.first(where: { $0.hasSuffix(".app") }) {
                return String(app.dropLast(".app".count))
            }
            return components.last.map(String.init) ?? command
        }
    }

    var processes: [Process]
    /// Why the listing may be incomplete. Nil when every process of this
    /// user was read.
    var failure: String?

    static func current() -> ProcessUsage {
        switch ProcessDirectories.listProcesses() {
        case .failure(let error):
            return ProcessUsage(
                processes: [],
                failure: "the system wouldn't list processes (\(String(cString: strerror(error.code.rawValue))))")
        case .success(let entries):
            let reader = ArgumentReader()
            return collect(
                entries, user: getuid(), workingDirectory: ProcessDirectories.workingDirectory,
                executable: executablePath, arguments: reader.read, isExiting: isExiting,
                pause: { usleep(10_000) })
        }
    }

    /// Reads this user's processes. A process that exited meanwhile, or is
    /// exiting, is fine. A read can also fail for a moment while a process
    /// starts a new program, so a failed read is tried again, up to
    /// `attempts` times; a process still unreadable then makes the listing
    /// incomplete.
    static func collect(
        _ entries: [ProcessDirectories.Entry], user: uid_t,
        workingDirectory: (Int32) -> Result<String, POSIXError>,
        executable: (Int32) -> Result<String, POSIXError>,
        arguments: (Int32) -> [String]?,
        isExiting: (Int32) -> Bool,
        attempts: Int = 3, pause: () -> Void = {}
    ) -> ProcessUsage {
        var processes: [Process] = []
        var failure: String?
        entries: for entry in entries where entry.uid == user && entry.pid > 0 {
            for attempt in 0..<max(attempts, 1) {
                if attempt > 0 { pause() }
                let directory = workingDirectory(entry.pid)
                let path = executable(entry.pid)
                if case .failure(let error) = directory, error.code == .ESRCH { continue entries }
                if case .failure(let error) = path, error.code == .ESRCH { continue entries }
                if case .success(let directory) = directory, case .success(let path) = path,
                    let arguments = arguments(entry.pid)
                {
                    processes.append(Process(
                        pid: entry.pid, command: entry.command, directory: directory, executable: path,
                        arguments: arguments))
                    continue entries
                }
                if isExiting(entry.pid) { continue entries }
            }
            failure = failure ?? "couldn't read what \(entry.command) (pid \(entry.pid)) is running"
        }
        return ProcessUsage(processes: processes, failure: failure)
    }

    /// Whether a process is gone, a zombie, or exiting: then what it runs
    /// can't matter any more.
    static func isExiting(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        guard size > 0 else { return true }
        return info.kp_proc.p_stat == SZOMB || info.kp_proc.p_flag & P_WEXIT != 0
    }

    /// Reads processes' arguments (sysctl KERN_PROCARGS2) into one buffer
    /// of KERN_ARGMAX bytes, allocated once per listing rather than once
    /// per process.
    final class ArgumentReader {
        private var buffer: [UInt8]

        init() {
            var maximum: Int32 = 0
            var length = MemoryLayout<Int32>.size
            var limit: [Int32] = [CTL_KERN, KERN_ARGMAX]
            if sysctl(&limit, 2, &maximum, &length, nil, 0) != 0 || maximum <= 0 { maximum = 1 << 20 }
            buffer = [UInt8](repeating: 0, count: Int(maximum))
        }

        /// argc, then the executable's path and padding, then argc
        /// NUL-terminated arguments. Nil when they can't be read.
        func read(_ pid: Int32) -> [String]? {
            var size = buffer.count
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
                return nil
            }
            let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            var index = MemoryLayout<Int32>.size
            while index < size, buffer[index] != 0 { index += 1 }
            while index < size, buffer[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < count, index < size {
                let start = index
                while index < size, buffer[index] != 0 { index += 1 }
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            return arguments
        }
    }

    static func executablePath(_ pid: Int32) -> Result<String, POSIXError> {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return .failure(POSIXError(errno == 0 ? ESRCH : errno)) }
        return .success(String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Processes that run from `path`, work in it, or name it (or something
    /// inside it) in an argument.
    func using(_ path: String) -> [Process] {
        processes.filter { process in
            Self.isInside(process.directory, path) || Self.isInside(process.executable, path)
                || process.arguments.contains { Self.mentions($0, path) }
        }
    }

    static func isInside(_ candidate: String, _ path: String) -> Bool {
        candidate == path || candidate.hasPrefix(path + "/")
    }

    /// Whether an argument names `path` or something inside it, alone or
    /// after `=` or `:` (`--user-data-dir=<path>`, `--output <path>/x`).
    static func mentions(_ argument: String, _ path: String) -> Bool {
        var searchStart = argument.startIndex
        while let range = argument.range(of: path, range: searchStart..<argument.endIndex) {
            let before = range.lowerBound == argument.startIndex ? nil : argument[argument.index(before: range.lowerBound)]
            let after = range.upperBound == argument.endIndex ? nil : argument[range.upperBound]
            let startsWell = before == nil || before == "=" || before == ":" || before == " " || before == "\"" || before == "'"
            let endsWell = after == nil || after == "/" || after == " " || after == "\"" || after == "'" || after == ":"
            if startsWell && endsWell { return true }
            searchStart = argument.index(after: range.lowerBound)
        }
        return false
    }
}
