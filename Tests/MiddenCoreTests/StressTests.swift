import Foundation
import Testing
@testable import MiddenCore

/// Peak resident memory of this process so far, in bytes.
private func peakResident() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)  // Bytes on macOS.
}

/// Large trees that take a while to build; run with MIDDEN_STRESS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MIDDEN_STRESS"] != nil))
struct StressTests {
    /// One folder with 200,000 entries: counted exactly, with time and
    /// memory printed for the record.
    @Test func aFolderWith200000Entries() throws {
        let dir = try TempDir()
        let folder = try dir.mkdir("huge")
        let created = Date()
        let data = Data(repeating: 0x5A, count: 100)
        for index in 0..<200_000 {
            FileManager.default.createFile(
                atPath: folder + "/entry-\(index)", contents: index % 10 == 0 ? data : nil)
        }
        let creation = Date().timeIntervalSince(created)

        let peakBefore = peakResident()
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let result = try Walker(root: dir.path, delegate: SizeOnly()).run()
        let seconds = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) / 1e9
        let peakAfter = peakResident()

        #expect(result.items == 200_001)
        #expect(result.readErrors == 0)
        let du = try #require(Int64(try sh(["du", "-skx", dir.path]).split(separator: "\t").first ?? "")) * 1024
        #expect(result.totalBytes == du)
        print("""
            STRESS 200,000 entries: created in \(String(format: "%.1f", creation)) s, \
            walked in \(String(format: "%.2f", seconds)) s, \
            peak resident \(peakBefore / 1_000_000) MB before the walk, \(peakAfter / 1_000_000) MB after
            """)
    }
}
