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

    @Test func capturesBothStreams() {
        let result = Command.run(["/bin/sh", "-c", "echo out; echo err >&2"])
        #expect(result.succeeded)
        #expect(result.output == "out\n")
        #expect(result.error == "err\n")
    }
}
