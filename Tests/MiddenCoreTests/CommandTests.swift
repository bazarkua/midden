import Foundation
import Testing
@testable import MiddenCore

@Suite struct CommandTests {
    @Test func killsACommandThatHangsWithOpenPipes() {
        let start = Date()
        let result = Command.run(["/bin/sleep", "10"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        #expect(result.error.contains("Timed out"))
    }

    /// The deadline used to apply only while stdout or stderr was open; a
    /// child that closed both and kept running was waited for without limit.
    @Test func killsACommandThatClosesItsOutputAndHangs() {
        let start = Date()
        let result = Command.run(["/bin/sh", "-c", "exec >&- 2>&-; sleep 8"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        #expect(result.error.contains("Timed out"))
    }

    @Test func reportsTheExitStatusOfACommandThatClosesItsOutput() {
        let result = Command.run(["/bin/sh", "-c", "exec >&- 2>&-; sleep 0.3; exit 3"], timeout: 10)
        #expect(result.status == 3)
    }

    /// A command's own children are stopped with it: a descendant that
    /// would write a file after the timeout must not get to.
    @Test func killsTheWholeProcessGroupOnTimeout() throws {
        let dir = try TempDir()
        let sentinel = dir.path("written-after-timeout")
        let start = Date()
        let result = Command.run(["/bin/sh", "-c", "(sleep 2; touch \"$0\") & sleep 30", sentinel], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.status == -1)
        Thread.sleep(forTimeInterval: 2.5)
        #expect(!FileManager.default.fileExists(atPath: sentinel))
    }

    /// The command exits at once, but a background child keeps its pipes
    /// open: the call returns at the deadline, unsuccessfully, and the
    /// child doesn't survive it.
    @Test func stopsAGrandchildHoldingThePipes() throws {
        let dir = try TempDir()
        let pidFile = dir.path("grandchild.pid")
        let start = Date()
        let result = Command.run(["/bin/sh", "-c", "sleep 30 & echo $! > \"$0\"", pidFile], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(!result.succeeded)
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let grandchild = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Gone, or at worst a zombie on its way out: give it a moment.
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(grandchild, 0) == 0
            if alive { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(!alive, "grandchild \(grandchild) survived the timeout")
    }

    /// A child that doesn't exit even after SIGKILL (stuck in the kernel):
    /// the call must still return, unsuccessfully, a bounded time after the
    /// deadline instead of waiting for it.
    @Test func returnsWhenTheKilledChildDoesNotExit() {
        let outcome = System.withDeadline(10) {
            Command.run(["/bin/sleep", "30"], environment: [:], timeout: 1) { _, _, _ in 0 }
        }
        let result = outcome
        #expect(result != nil, "Command.run waited for a child that never exited")
        #expect(result?.status == -1)
        #expect(result?.error.contains("didn't exit") == true, "\(result?.error ?? "")")
    }

    /// When the exit status can't be read, the command didn't succeed.
    @Test func anUnreadableExitStatusIsAFailure() {
        let result = Command.run(["/usr/bin/true"], environment: [:], timeout: 10) { _, _, _ in
            errno = ECHILD
            return -1
        }
        #expect(result.status == -1)
        #expect(!result.succeeded)
        #expect(result.error.contains("exit status"), "\(result.error)")
    }

    @Test func capturesBothStreams() {
        let result = Command.run(["/bin/sh", "-c", "echo out; echo err >&2"])
        #expect(result.succeeded)
        #expect(result.output == "out\n")
        #expect(result.error == "err\n")
    }
}
