import Foundation

struct CommandResult: Sendable {
    /// Exit status; -1 if it couldn't start or was killed.
    var status: Int32
    var output: String
    var error: String

    var succeeded: Bool { status == 0 }

    /// stderr if there is any, else stdout, for messages shown to the user.
    var message: String {
        let text = error.isEmpty ? output : error
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs command-line tools synchronously, capturing stdout and stderr.
/// Call it from a thread that may block, never from the cooperative pool.
enum Command {
    /// Searched after PATH. Apps opened from Finder get a minimal PATH
    /// without Homebrew's folders.
    static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static var searchPath: [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var seen = Set<String>()
        return (path.split(separator: ":").map(String.init) + extraSearchPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Full path of an executable, or nil.
    static func find(_ tool: String) -> String? {
        for directory in searchPath {
            let candidate = directory + "/" + tool
            guard access(candidate, X_OK) == 0 else { continue }
            // /usr/bin/git and friends are stubs that open an "install the
            // command line developer tools" dialog when the tools are missing.
            if directory == "/usr/bin", ["git", "xcrun"].contains(tool), !developerToolsInstalled {
                continue
            }
            return candidate
        }
        return nil
    }

    static var developerToolsInstalled: Bool {
        let fileManager = FileManager.default
        if let developer = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
            fileManager.fileExists(atPath: developer + "/usr/bin")
        {
            return true
        }
        return fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    }

    /// Runs `arguments[0]` (a path, or a name looked up with `find`) with
    /// stdin from /dev/null. Kills it after `timeout` seconds.
    static func run(
        _ arguments: [String],
        environment extra: [String: String] = [:],
        timeout: TimeInterval = 120
    ) -> CommandResult {
        guard let tool = arguments.first,
            let executable = tool.contains("/") ? tool : find(tool)
        else {
            return CommandResult(status: -1, output: "", error: "\(arguments.first ?? "") isn't installed.")
        }

        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { return failure(errno) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0]); close(outputPipe[1])
            return failure(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdin, stdout and stderr reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment.merge(extra) { _, new in new }
        let argv = ([executable] + arguments.dropFirst()).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outputPipe[1])
        close(errorPipe[1])
        guard spawned == 0 else {
            close(outputPipe[0])
            close(errorPipe[0])
            return failure(spawned)
        }

        // Drain both pipes together so a child filling one can't block.
        var collected = [Data(), Data()]
        var fds = [
            pollfd(fd: outputPipe[0], events: Int16(POLLIN), revents: 0),
            pollfd(fd: errorPipe[0], events: Int16(POLLIN), revents: 0),
        ]
        let deadline = Date(timeIntervalSinceNow: timeout)
        var killed = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while fds.contains(where: { $0.fd >= 0 }) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                kill(pid, SIGKILL)
                killed = true
                break
            }
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(remaining, 1) * 1000))
            if ready < 0 && errno != EINTR { break }
            for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    collected[index].append(contentsOf: buffer[..<count])
                } else if count == 0 || errno != EINTR {
                    close(fds[index].fd)
                    fds[index].fd = -1
                }
            }
        }
        for fd in fds where fd.fd >= 0 { close(fd.fd) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // WIFEXITED / WEXITSTATUS, which Swift doesn't import.
        let exited = status & 0x7f == 0
        let error = String(decoding: collected[1], as: UTF8.self)
        return CommandResult(
            status: exited && !killed ? (status >> 8) & 0xff : -1,
            output: String(decoding: collected[0], as: UTF8.self),
            error: killed ? "Timed out after \(Int(timeout)) seconds. " + error : error)
    }

    private static func failure(_ code: Int32) -> CommandResult {
        CommandResult(status: -1, output: "", error: String(cString: strerror(code)))
    }
}
