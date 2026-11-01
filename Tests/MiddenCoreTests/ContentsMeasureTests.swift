import Foundation
import Synchronization
import Testing
@testable import MiddenCore

// What Logs and SwiftPM cleaning would delete is measured from the scan's
// own listings, under its watchdog, thread admission and cancellation, not
// by a second walk afterwards; and a folder that wasn't read shows.

/// Counts listings per path, and can block or break chosen ones.
private final class ListingProbe: Sendable {
    let counts = Mutex<[String: Int]>([:])
    let blocked = Mutex<Set<String>>([])
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let failing: [String: POSIXErrorCode]
    let partial: Set<String>

    init(block: Set<String> = [], failing: [String: POSIXErrorCode] = [:], partial: Set<String> = []) {
        blocked.withLock { $0 = block }
        self.failing = failing
        self.partial = partial
    }

    var lister: ContentsSurvey.Lister {
        { [self] path, reader throws(POSIXError) in
            counts.withLock { $0[path, default: 0] += 1 }
            if blocked.withLock({ $0.contains(path) }) {
                entered.withLock { $0 = true }
                release.wait()
            }
            if let code = failing[path] { throw POSIXError(code) }
            var listing = try reader.listing(atPath: path)
            if partial.contains(path) {
                listing.entries = Array(listing.entries.prefix(1))
                listing.markIncomplete(POSIXError(.EIO))
            }
            return listing
        }
    }
}

@Suite struct ContentsMeasureTests {
    private func makeHome() throws -> TempDir {
        let home = try TempDir("home")
        for folder in ["App", "App/rotated", "DiagnosticReports", "Locked"] {
            for index in 0..<3 {
                try home.write("Library/Logs/\(folder)/old-\(index).log", bytes: 20_000)
                try home.touch("Library/Logs/\(folder)/old-\(index).log", daysAgo: 10)
            }
        }
        try home.write("code/tool/Package.swift", text: "// swift-tools-version: 6.0\n")
        try home.touch("code/tool/Package.swift", daysAgo: 30)
        try home.write("code/tool/.build/workspace-state.json", text: "{}")
        try home.write("code/tool/.build/checkouts/dep/Edited.swift", bytes: 20_000)
        try home.write("code/tool/.build/arm64-apple-macosx/debug/Tool.build/main.o", bytes: 200_000)
        try home.write("code/tool/.build/arm64-apple-macosx/output-file-map.json", bytes: 20_000)
        return home
    }

    private func options(_ home: TempDir, _ probe: ListingProbe, threads: WalkerThreads = .process) -> ScanOptions {
        var options = ScanOptions.fakeHome(home, minimumBytes: 1)
        options.lister = probe.lister
        options.walkerThreads = threads
        options.processUsage = { ProcessUsage(processes: []) }
        return options
    }

    /// Every folder under Logs and .build is listed exactly once: by the
    /// scan's walk, which also measures them. Nothing walks them again.
    @Test func measuresDuringTheWalkWithoutListingAgain() async throws {
        let home = try makeHome()
        let probe = ListingProbe()
        let report = try await Scanner(options: options(home, probe)).scan()
        let counts = probe.counts.withLock { $0 }
        let measured = counts.filter { $0.key.hasPrefix(home.path("Library/Logs")) || $0.key.hasPrefix(home.path("code/tool/.build")) }
        #expect(measured.count == 11, "\(measured.keys.sorted())")
        #expect(measured.values.allSatisfy { $0 == 1 }, "\(measured)")

        let logs = try #require(report.findings.first { $0.path == home.path("Library/Logs") })
        #expect(logs.safety == .safe)
        #expect(logs.checks.first { $0.id == "measured" }?.passed == true)
        let build = try #require(report.findings.first { $0.path == home.path("code/tool/.build") })
        #expect(build.checks.first { $0.id == "measured" }?.passed == true)
    }

    /// A folder under Logs that fails to list, one listed only partly, and
    /// a .build folder that fails: the measures say they're incomplete,
    /// and neither item stays Safe.
    @Test func foldersNotReadShowInTheMeasure() async throws {
        let home = try makeHome()
        let probe = ListingProbe(
            failing: [home.path("Library/Logs/Locked"): .EACCES,
                      home.path("code/tool/.build/arm64-apple-macosx/debug"): .EIO],
            partial: [home.path("Library/Logs/App")])
        let report = try await Scanner(options: options(home, probe)).scan()

        let logs = try #require(report.findings.first { $0.path == home.path("Library/Logs") })
        let logsCheck = try #require(logs.checks.first { $0.id == "measured" })
        #expect(!logsCheck.passed)
        #expect(logsCheck.detail.contains("couldn't read"), "\(logsCheck)")
        #expect(logs.safety == .review)
        let build = try #require(report.findings.first { $0.path == home.path("code/tool/.build") })
        #expect(build.checks.first { $0.id == "measured" }?.passed == false)
        #expect(build.safety == .review)
    }

    /// A listing under Logs that never returns: cancelling the scan returns
    /// promptly, and once the listing returns its thread leaves, with no
    /// slot or given-up listing left behind.
    @Test func aBlockedListingInLogsIsCancelledPromptly() async throws {
        let home = try makeHome()
        let blocked = home.path("Library/Logs/App/rotated")
        let probe = ListingProbe(block: [blocked])
        let threads = WalkerThreads(limit: 16)
        let scanner = Scanner(options: options(home, probe, threads: threads))
        let task = Task { try await scanner.scan() }
        // The walk is stuck in the listing.
        let waitUntil = Date(timeIntervalSinceNow: 10)
        while !probe.entered.withLock({ $0 }), Date() < waitUntil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(probe.entered.withLock { $0 })

        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled scan returned a report")
        } catch {
            #expect(error as? MiddenError == .cancelled)
        }
        #expect(Date().timeIntervalSince(cancelled) < 2)

        probe.release.signal()
        let deadline = Date(timeIntervalSinceNow: 5)
        while (threads.held > 0 || threads.abandonedCount > 0), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(threads.held == 0)
        #expect(threads.abandonedCount == 0)
    }

    /// The cleaner measures again under the walker's watchdog: a listing
    /// that stalls is given up, and the plan says what wasn't read.
    @Test func theCleanersMeasureGivesUpAStalledListing() async throws {
        let home = try makeHome()
        let probe = ListingProbe(block: [home.path("Library/Logs/DiagnosticReports")])
        var engine = try CleanEngine(home: home.url)
        engine.runningApp = { _ in nil }
        engine.contentsLister = probe.lister
        engine.contentsStallTimeout = 0.3
        let started = Date()
        let plan = engine.plan(home.path("Library/Logs"))
        #expect(Date().timeIntervalSince(started) < 3)
        probe.release.signal()
        let finding = try #require(plan.finding)
        #expect(finding.checks.first { $0.id == "measured" }?.passed == false)
        #expect(finding.safety == .review)
    }
}

/// Logs and .build trees big enough to time; run with MIDDEN_STRESS=1.
/// Prints the scan time, the folders the scan listed under them, and what a
/// separate measuring walk of the same folders takes, for the record.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MIDDEN_STRESS"] != nil))
struct ContentsMeasureStressTests {
    @Test func largeLogsAndBuildFolders() async throws {
        let home = try TempDir("home")
        let data = Data(repeating: 0x5A, count: 2_000)
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        func fill(_ folder: String, folders: Int, files: Int) throws {
            for index in 0..<folders {
                let path = try home.mkdir("\(folder)/d\(index)")
                for file in 0..<files {
                    FileManager.default.createFile(atPath: "\(path)/f\(file)", contents: data, attributes: [.modificationDate: old])
                }
            }
        }
        try fill("Library/Logs", folders: 400, files: 50)
        for package in 0..<4 {
            try home.write("code/p\(package)/Package.swift", text: "// swift-tools-version: 6.0\n")
            try home.touch("code/p\(package)/Package.swift", daysAgo: 30)
            try fill("code/p\(package)/.build/arm64-apple-macosx", folders: 200, files: 50)
        }

        let probe = ListingProbe()
        var options = ScanOptions.fakeHome(home, minimumBytes: 1)
        options.lister = probe.lister
        options.processUsage = { ProcessUsage(processes: []) }
        let started = Date()
        let report = try await Scanner(options: options).scan()
        let scanTime = Date().timeIntervalSince(started)
        let counts = probe.counts.withLock { $0 }
        let underPolicies = counts.filter { $0.key.contains("/Library/Logs") || $0.key.contains("/.build") }

        let roots = [home.path("Library/Logs")] + (0..<4).map { home.path("code/p\($0)/.build") }
        let separate = Date()
        for root in roots {
            let policy: ContentsPolicy = root.hasSuffix("Logs")
                ? .agedFiles(minimumAge: 7 * 86_400) : .allExcept(BuildFolderKind.swiftPMKept)
            _ = ContentsSurvey.measure(policy, root, now: Date())
        }
        let separateTime = Date().timeIntervalSince(separate)
        print("""
            CONTENTS-STRESS items=\(report.itemsScanned) scan=\(String(format: "%.2f", scanTime))s \
            listings-under-policies=\(underPolicies.count) relisted=\(underPolicies.values.filter { $0 > 1 }.count) \
            separate-measuring-walks=\(String(format: "%.2f", separateTime))s
            """)
        #expect(underPolicies.values.allSatisfy { $0 == 1 })
    }
}
