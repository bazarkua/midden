import Foundation
import Synchronization

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

/// Whether this process runs in the App Sandbox (the App Store build).
enum Sandbox {
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
}

/// Runs command-line tools synchronously, capturing stdout and stderr.
/// Call it from a thread that may block, never from the cooperative pool.
enum Command {
    /// For the git commands Midden runs. No optional locks: `git status`
    /// must not rewrite the index of a worktree Midden only looks at. No
    /// file-system monitor: with core.fsmonitor=true, git would start a
    /// daemon in every worktree Midden checks and leave it running. And
    /// untracked files always shown: `git worktree remove` checks that a
    /// worktree is clean with its own `git status`, which would otherwise
    /// follow a user's status.showUntrackedFiles=no and remove a worktree
    /// holding untracked files. These settings outrank every config file.
    static let quietGit = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "status.showUntrackedFiles", "GIT_CONFIG_VALUE_1": "all",
    ]

    /// Applied to the environment of every command: a value sets a
    /// variable, nil removes it. Empty in the app; tests use it to keep the
    /// machine's git configuration away from the git commands they cause.
    static let environmentOverrides = Mutex<[String: String?]>([:])

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
        if tool == "git" { return git() }
        // xcrun refuses to run in the App Sandbox.
        if tool == "xcrun", Sandbox.isActive { return nil }
        return search(tool)
    }

    /// The git to run. Inside the App Sandbox, /usr/bin/git and xcrun can't
    /// be used, so git is taken from the developer folder they would pick:
    /// the one /var/db/xcode_select_link points to, else the Command Line
    /// Tools. Outside the sandbox, the user's own git from PATH is preferred.
    static func git(
        sandboxed: Bool = Sandbox.isActive,
        xcodeSelectLink: String = "/var/db/xcode_select_link",
        commandLineTools: String = "/Library/Developer/CommandLineTools"
    ) -> String? {
        guard sandboxed else { return search("git") }
        var candidates: [String] = []
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: xcodeSelectLink) {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates.append(commandLineTools + "/usr/bin/git")
        return candidates.first { access($0, X_OK) == 0 }
    }

    private static func search(_ tool: String) -> String? {
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
        run(arguments, environment: extra, timeout: timeout, waitpid: Darwin.waitpid)
    }

    /// `run` with waitpid(2) and the budget of children replaceable, so
    /// tests can simulate a child that never exits or a status that can't
    /// be read, and fill a budget without touching the shared one.
    static func run(
        _ arguments: [String],
        environment extra: [String: String],
        timeout: TimeInterval,
        children: CommandChildren = .shared,
        waitpid: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
    ) -> CommandResult {
        guard let tool = arguments.first,
            let executable = tool.contains("/") ? tool : find(tool)
        else {
            return CommandResult(status: -1, output: "", error: "\(arguments.first ?? "") isn't installed.")
        }
        // A monotonic deadline: the wall clock can jump. It covers the wait
        // for a slot too.
        let deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + UInt64(max(timeout, 0) * 1e9)

        // A slot for the child, reserved before anything is started and held
        // until the child is reaped: running and lingering children together
        // never exceed the limit.
        guard children.reserve(until: deadline) else {
            return CommandResult(
                status: -1, output: "",
                error: "\(children.limit) commands are already running or haven't exited after being stopped, so \(tool) wasn't started.")
        }

        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            let code = errno
            children.release()
            return failure(code)
        }
        guard pipe(&errorPipe) == 0 else {
            let code = errno
            close(outputPipe[0]); close(outputPipe[1])
            children.release()
            return failure(code)
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
        // Only stdin, stdout and stderr reach the child, and it leads a new
        // process group, so a timeout can stop everything it started.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let environment = Self.environment(
            inherited: ProcessInfo.processInfo.environment,
            overrides: environmentOverrides.withLock { $0 }, extra: extra)
        let argv = ([executable] + arguments.dropFirst()).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        // The deadline may have passed during the setup above: then nothing
        // is started.
        if clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= deadline {
            for fd in outputPipe + errorPipe { close(fd) }
            children.release()
            return CommandResult(
                status: -1, output: "", error: "Timed out after \(Int(timeout)) seconds before \(tool) started.")
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outputPipe[1])
        close(errorPipe[1])
        guard spawned == 0 else {
            close(outputPipe[0])
            close(errorPipe[0])
            children.release()
            return failure(spawned)
        }

        // Drain both pipes together so a child filling one can't block.
        var collected = [Data(), Data()]
        var fds = [
            pollfd(fd: outputPipe[0], events: Int16(POLLIN), revents: 0),
            pollfd(fd: errorPipe[0], events: Int16(POLLIN), revents: 0),
        ]
        func secondsLeft() -> Double {
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            return now >= deadline ? 0 : Double(deadline - now) / 1e9
        }
        var killed = false
        // Killed because the deadline passed, as opposed to after an error.
        var timedOut = false
        var stoppedAt: UInt64 = 0
        func stop() {
            // The whole group: children the command started go with it. A
            // process that left the group (setsid) is out of reach.
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            killed = true
            stoppedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while fds.contains(where: { $0.fd >= 0 }) {
            let remaining = secondsLeft()
            if remaining <= 0 {
                timedOut = true
                stop()
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

        // The deadline holds until the child exits: one that closes stdout
        // and stderr and keeps running must not be waited for without limit.
        // Nor does a killed child get waited for without limit: SIGKILL
        // doesn't end a process stuck in the kernel. Every wait here is
        // nonblocking; a child still there `exitGrace` after the kill is
        // handed to `children`, with its slot, to be reaped when it exits,
        // and the command fails.
        var status: Int32 = 0
        var reaped = false
        var statusUnknown = false
        var notOurs = false
        var leftBehind = false
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                reaped = true
                break
            }
            // Interrupted: try again, but only after the deadline and grace
            // checks below, which hold on every turn.
            if result < 0, errno != EINTR {
                statusUnknown = true
                // Only ECHILD says it isn't our child any more. Any other
                // error leaves it ours, maybe still running: stop it, and
                // let the watch reap it below.
                notOurs = errno == ECHILD
                if !notOurs, !killed { stop() }
                break
            }
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            if !killed, now >= deadline {
                timedOut = true
                stop()
            } else if killed, now >= stoppedAt + UInt64(Self.exitGrace * 1e9) {
                leftBehind = true
                break
            }
            usleep(5_000)
        }
        if reaped || notOurs {
            // Reaped here, or no longer our child: either way it's gone.
            children.release()
        } else {
            // Still there after being stopped, or its status couldn't be
            // read: the slot goes with it, without a gap, until the watch
            // has reaped it.
            children.handOver(pid)
        }
        // WIFEXITED / WEXITSTATUS, which Swift doesn't import. An unknown
        // status is a failure, never a success.
        let exited = reaped && status & 0x7f == 0
        var error = String(decoding: collected[1], as: UTF8.self)
        if leftBehind { error = "It didn't exit after being stopped. " + error }
        if statusUnknown { error = "Couldn't read its exit status. " + error }
        if timedOut { error = "Timed out after \(Int(timeout)) seconds. " + error }
        return CommandResult(
            status: exited && !killed ? (status >> 8) & 0xff : -1,
            output: String(decoding: collected[0], as: UTF8.self),
            error: error)
    }

    /// How long a killed command gets to exit before run() stops waiting.
    static let exitGrace: TimeInterval = 2

    /// Inherited variables that never reach a command. They choose which
    /// repository, work tree, index or object store git works on, or add
    /// configuration. Exported by a git hook, an alias or a shell that
    /// started Midden, they'd make `git -C <worktree> status` check another
    /// repository and call a dirty worktree clean.
    static let removedVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE",
        "GIT_CONFIG_PARAMETERS",
    ]

    /// The environment a command runs with: Midden's own without
    /// `removedVariables`, PATH extended, then the overrides, then the
    /// command's extra variables.
    static func environment(
        inherited: [String: String], overrides: [String: String?], extra: [String: String]
    ) -> [String: String] {
        var environment = inherited.filter { !removedVariables.contains($0.key) }
        environment["PATH"] = searchPath.joined(separator: ":")
        for (name, value) in overrides {
            environment[name] = value
        }
        environment.merge(extra) { _, new in new }
        return environment
    }

    private static func failure(_ code: Int32) -> CommandResult {
        CommandResult(status: -1, output: "", error: String(cString: strerror(code)))
    }
}

/// Slots for the processes Command.run starts, shared by every run given
/// the same value (by default the whole process). A slot is reserved
/// atomically before a command is spawned and held until its process is
/// reaped, or known not to be this process's child any more. A killed
/// command that hasn't exited keeps its slot: it's handed to an exit watch
/// that reaps it whenever it exits, without a thread waiting on it and
/// without needing another command to run. So running plus lingering
/// children never exceed `limit`.
final class CommandChildren: Sendable {
    /// Watches a lingering child and calls `reaped` once it has been reaped.
    typealias Watch = @Sendable (_ pid: pid_t, _ reaped: @escaping @Sendable () -> Void) -> Void

    let limit: Int
    private let watch: Watch
    private struct State {
        var held = 0
        var highWater = 0
        var lingering = 0
    }
    private let state = Mutex(State())

    static let shared = CommandChildren(limit: 32)

    init(limit: Int, watch: @escaping Watch = CommandChildren.watchExit) {
        self.limit = limit
        self.watch = watch
    }

    var held: Int { state.withLock { $0.held } }
    var lingering: Int { state.withLock { $0.lingering } }
    /// The most slots held at once, for tests.
    var highWater: Int { state.withLock { $0.highWater } }

    /// Takes a slot, waiting until `deadline` (CLOCK_MONOTONIC_RAW ns) for
    /// one at most.
    func reserve(until deadline: UInt64) -> Bool {
        while true {
            // Expired: nothing is taken, even if a slot is free.
            if clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= deadline { return false }
            let reserved = state.withLock { state in
                guard state.held < limit else { return false }
                state.held += 1
                state.highWater = max(state.highWater, state.held)
                return true
            }
            if reserved { return true }
            usleep(5_000)
        }
    }

    /// The child was reaped, never started, or isn't ours any more.
    func release() {
        state.withLock { $0.held -= 1 }
    }

    /// The child is still there after being killed: its slot stays taken
    /// until the watch reports it reaped.
    func handOver(_ pid: pid_t) {
        state.withLock { $0.lingering += 1 }
        watch(pid) { [self] in
            state.withLock { state in
                state.lingering -= 1
                state.held -= 1
            }
        }
    }

    /// Reaps `pid` when it exits, through the process-wide reaper.
    static let watchExit: Watch = { pid, reaped in
        ChildReaper.shared.watch(pid, reaped: reaped)
    }
}

/// Reaps the lingering children handed to it, on one serial queue, with no
/// thread waiting on any of them.
///
/// An exit notification doesn't mean the child can be reaped yet: the
/// kernel sends NOTE_EXIT before the process becomes a zombie, and only
/// once. So each child is checked when it's handed over, when its exit is
/// reported, and on a timer that backs off from 10 ms to 1 s, until
/// waitpid reaps it or says it isn't ours (ECHILD). Any other answer (0,
/// or another error) means "try again later". The completion runs exactly
/// once, and stops every further check. Command.run hands over at most its
/// budget's worth of children, so the timers are bounded too.
final class ChildReaper: Sendable {
    /// waitpid(pid, WNOHANG): its result, and errno when it's negative.
    typealias Wait = @Sendable (_ pid: pid_t) -> (result: pid_t, error: Int32)
    /// Arms exit notifications for `pid`, calling `fired` on `queue` for
    /// each; returns a function that disarms them.
    typealias ExitEvents = @Sendable (
        _ pid: pid_t, _ queue: DispatchQueue, _ fired: @escaping @Sendable () -> Void
    ) -> (@Sendable () -> Void)

    static let shared = ChildReaper()

    private let queue = DispatchQueue(label: "midden.child-reaper")
    private let wait: Wait
    private let exitEvents: ExitEvents
    let firstRetry: TimeInterval
    let longestRetry: TimeInterval

    init(
        wait: @escaping Wait = ChildReaper.waitNoHang,
        exitEvents: @escaping ExitEvents = ChildReaper.processSource,
        firstRetry: TimeInterval = 0.01, longestRetry: TimeInterval = 1
    ) {
        self.wait = wait
        self.exitEvents = exitEvents
        self.firstRetry = firstRetry
        self.longestRetry = longestRetry
    }

    static let waitNoHang: Wait = { pid in
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return (result, result < 0 ? errno : 0)
    }

    static let processSource: ExitEvents = { pid, queue, fired in
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: fired)
        source.resume()
        return { source.cancel() }
    }

    /// One child being watched. Only touched on the reaper's queue.
    private final class Tracked: @unchecked Sendable {
        let pid: pid_t
        let reaped: @Sendable () -> Void
        var done = false
        var delay: TimeInterval
        var disarm: (@Sendable () -> Void)?
        var timer: (any DispatchSourceTimer)?

        init(pid: pid_t, delay: TimeInterval, reaped: @escaping @Sendable () -> Void) {
            self.pid = pid
            self.delay = delay
            self.reaped = reaped
        }
    }

    /// Watches `pid`, a child of this process, and calls `reaped` exactly
    /// once, after waitpid has reaped it or reported ECHILD.
    func watch(_ pid: pid_t, reaped: @escaping @Sendable () -> Void) {
        let tracked = Tracked(pid: pid, delay: firstRetry, reaped: reaped)
        queue.async { [self] in
            tracked.disarm = exitEvents(pid, queue) { [self] in
                // Reported exited: look now, and soon again if it isn't
                // waitable yet.
                tracked.delay = firstRetry
                check(tracked)
            }
            // It may have exited before the notification was armed.
            check(tracked)
        }
    }

    /// On the queue: reap if possible, else schedule the next look.
    private func check(_ tracked: Tracked) {
        guard !tracked.done else { return }
        let (result, error) = wait(tracked.pid)
        if result == tracked.pid || (result < 0 && error == ECHILD) {
            tracked.done = true
            tracked.disarm?()
            tracked.timer?.cancel()
            tracked.disarm = nil
            tracked.timer = nil
            tracked.reaped()
            return
        }
        // Not yet waitable, or a recoverable error: look again later.
        tracked.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tracked.delay)
        timer.setEventHandler { [self] in check(tracked) }
        tracked.timer = timer
        tracked.delay = min(tracked.delay * 2, longestRetry)
        timer.resume()
    }
}
