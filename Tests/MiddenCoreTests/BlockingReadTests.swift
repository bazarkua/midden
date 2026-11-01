import Foundation
import Testing
@testable import MiddenCore

/// Small metadata files Midden reads (a worktree's `.git` file, a reflog, a
/// lock reason) can be replaced by a FIFO between the listing and the read.
/// open() of a FIFO for reading blocks until a writer appears, and nothing
/// would ever write: the scan or the clean would hang there for good.
@Suite struct BlockingReadTests {
    /// Makes a FIFO and returns a function that unblocks any reader still
    /// waiting in open(), so a failing test doesn't leave a thread behind.
    private func makeFIFO(_ path: String) throws -> () -> Void {
        try #require(mkfifo(path, 0o644) == 0)
        return {
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
    }

    @Test func aGitFileThatIsAFIFODoesNotBlock() throws {
        let dir = try TempDir()
        let release = try makeFIFO(dir.path(".git"))
        defer { release() }
        let file = dir.path(".git")
        let read = System.withDeadline(3) { Classifier.readSmallFile(file) }
        let finished = try #require(read, "readSmallFile blocked on a FIFO")
        #expect(finished == nil)
    }

    @Test func aReflogThatIsAFIFODoesNotBlock() throws {
        let dir = try TempDir()
        try dir.mkdir("logs")
        let release = try makeFIFO(dir.path("logs/HEAD"))
        defer { release() }
        let log = dir.path("logs/HEAD")
        let read = System.withDeadline(3) { WorktreeAuditor.lastReflogTime(log) }
        let finished = try #require(read, "lastReflogTime blocked on a FIFO")
        #expect(finished == nil)
    }

    @Test func externalWorktreeRecordThatIsAFIFODoesNotBlock() throws {
        let dir = try TempDir()
        try dir.mkdir("repo/.git/worktrees/wt")
        let release = try makeFIFO(dir.path("repo/.git/worktrees/wt/gitdir"))
        defer { release() }
        let (repository, home) = (dir.path("repo/.git"), dir.path)
        let discovered = System.withDeadline(3) {
            ExternalWorktrees.discover(gitDirectories: [repository], home: home).worktrees.count
        }
        #expect(discovered == 0, "discovery blocked on a FIFO")
    }
}
