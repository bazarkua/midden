import Foundation
import Testing
@testable import MiddenCore

@Suite struct DurationTests {
    /// The reported scan time was measured before the space map was built,
    /// so building it never counted.
    @Test func reportedDurationIncludesBuildingTheSpaceMap() throws {
        let home = try TempDir("home")
        try home.write("Library/Caches/com.example.fake/blob", bytes: 10_000)
        var options = ScanOptions(home: home.url)
        options.threadCount = 2
        options.fullDiskAccess = true
        var engine = ScanEngine(options: options)
        engine.buildSpaceMap = { records, root, findings, aliases in
            Thread.sleep(forTimeInterval: 0.5)
            return SpaceMap.build(records, root: root, findings: findings, aliases: aliases, floor: 0)
        }
        let report = try engine.run(progress: { _ in }, cancellation: CancellationFlag())
        #expect(report.duration >= 0.5, "\(report.duration)")
        #expect(report.spaceMap != nil)
    }
}
