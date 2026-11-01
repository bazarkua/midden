import Foundation

/// The working directory of every process the user runs, read in-process.
///
/// sysctl(KERN_PROC_ALL) lists the processes and proc_pidinfo
/// (PROC_PIDVNODEPATHINFO) gives each one's working directory. Unlike lsof,
/// this works inside the App Sandbox. A check that can't run must never pass,
/// so anything short of a complete listing is reported in `failure`.
struct ProcessDirectories: Sendable {
    struct Process: Sendable, Hashable {
        var pid: Int32
        var command: String
        var directory: String
        /// git's file-system monitor (`git fsmonitor--daemon`), which
        /// `core.fsmonitor=true` starts and leaves running in a worktree.
        var isGitFileMonitor = false
    }

    /// A process as the system lists it.
    struct Entry: Sendable, Hashable {
        var pid: Int32
        var uid: uid_t
        var command: String
    }

    var processes: [Process]
    /// Why the listing may be incomplete. Nil when every process of this user
    /// was checked.
    var failure: String?

    init(processes: [Process], failure: String? = nil) {
        self.processes = processes
        self.failure = failure
    }

    static func current() -> ProcessDirectories {
        switch listProcesses() {
        case .failure(let error):
            return ProcessDirectories(
                processes: [],
                failure: "the system wouldn't list processes (\(String(cString: strerror(error.code.rawValue))))")
        case .success(let entries):
            return collect(
                entries, user: getuid(), workingDirectory: workingDirectory, arguments: processArguments)
        }
    }

    /// Keeps this user's processes and reads their working directories. A
    /// process that exited meanwhile (ESRCH) is fine; any other error means
    /// the listing is incomplete.
    static func collect(
        _ entries: [Entry], user: uid_t, workingDirectory: (Int32) -> Result<String, POSIXError>,
        arguments: (Int32) -> [String]? = { _ in nil }
    ) -> ProcessDirectories {
        var processes: [Process] = []
        var failure: String?
        for entry in entries where entry.uid == user && entry.pid > 0 {
            switch workingDirectory(entry.pid) {
            case .success(let directory):
                // Recognized precisely: a git process whose arguments include
                // fsmonitor--daemon. Arguments that can't be read count as
                // any other program.
                let monitor = entry.command == "git"
                    && (arguments(entry.pid)?.contains("fsmonitor--daemon") ?? false)
                processes.append(Process(
                    pid: entry.pid, command: entry.command, directory: directory, isGitFileMonitor: monitor))
            case .failure(let error) where error.code == .ESRCH:
                continue
            case .failure(let error):
                failure = failure
                    ?? "couldn't read where \(entry.command) (pid \(entry.pid)) is working (\(String(cString: strerror(error.code.rawValue))))"
            }
        }
        return ProcessDirectories(processes: processes, failure: failure)
    }

    /// Every process on the system, from sysctl(KERN_PROC_ALL).
    static func listProcesses() -> Result<[Entry], POSIXError> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The list can grow between asking for its size and reading it.
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return .failure(POSIXError(errno)) }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = buffer.count * stride
            if sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 {
                let entries = buffer.prefix(size / stride).compactMap { info -> Entry? in
                    // Zombies have no working directory.
                    guard info.kp_proc.p_stat != SZOMB else { return nil }
                    let command = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
                        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    return Entry(pid: info.kp_proc.p_pid, uid: info.kp_eproc.e_ucred.cr_uid, command: command)
                }
                return .success(entries)
            }
            guard errno == ENOMEM else { return .failure(POSIXError(errno)) }
        }
        return .failure(POSIXError(.ENOMEM))
    }

    /// A process's arguments, from sysctl(KERN_PROCARGS2): argc, then the
    /// executable's path and padding, then argc NUL-terminated arguments.
    static func processArguments(_ pid: Int32) -> [String]? {
        var maximum: Int32 = 0
        var length = MemoryLayout<Int32>.size
        var limit: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limit, 2, &maximum, &length, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // The executable's path.
        while index < size, buffer[index] == 0 { index += 1 }  // Padding.
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func workingDirectory(_ pid: Int32) -> Result<String, POSIXError> {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return .failure(POSIXError(errno == 0 ? ESRCH : errno))
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return .success(path)
    }

    /// Processes working in `path` or below it.
    func inside(_ path: String) -> [Process] {
        processes.filter { $0.directory == path || $0.directory.hasPrefix(path + "/") }
    }
}
