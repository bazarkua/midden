import Foundation
import Testing
@testable import MiddenCore

@Test func safetyOrdersFromSafeToInfo() {
    #expect(Safety.allCases.sorted() == [.safe, .review, .info])
}

@Test func readsCleanResultsSavedBeforeFreedBytes() throws {
    let old = Data(#"{"id": "/x", "ok": true}"#.utf8)
    let result = try JSONDecoder().decode(CleanResult.self, from: old)
    #expect(result == CleanResult(id: "/x", ok: true, freedBytes: 0))
    let roundTrip = try JSONDecoder().decode(
        CleanResult.self, from: JSONEncoder().encode(CleanResult(id: "/y", ok: false, message: "m", freedBytes: 42)))
    #expect(roundTrip.freedBytes == 42)
}

@Test func readsSafetyChecksSavedBeforeIds() throws {
    let old = Data(#"{"title": "Not locked", "passed": true, "detail": "d"}"#.utf8)
    let check = try JSONDecoder().decode(SafetyCheck.self, from: old)
    #expect(check.id == "")
    #expect(check.title == "Not locked")
}

@Test func readsReportsSavedBeforeTheCountsWereSplit() throws {
    let old = Data("""
        {"home": "/h", "startedAt": 0, "duration": 1, "itemsScanned": 2, "bytesScanned": 3,
         "disk": {"total": 10, "free": 5}, "findings": [], "topFolders": [],
         "unreadableCount": 7, "needsFullDiskAccess": false}
        """.utf8)
    let report = try JSONDecoder().decode(ScanReport.self, from: old)
    #expect(report.unreadableCount == 7)
    #expect(report.readErrors == 7)
    #expect(report.skippedWithoutFullDiskAccess == 0)
    #expect(report.spaceMap == nil)
}

@Test func readsSpaceNodesSavedBeforeIsOther() throws {
    let old = Data(#"{"name": "a", "path": "/a", "bytes": 1, "isDirectory": true, "children": []}"#.utf8)
    let node = try JSONDecoder().decode(SpaceNode.self, from: old)
    #expect(node.isOther == false)
    #expect(node.findingID == nil)
}

@Test func manualActionsAreNotAutomatic() {
    #expect(CleanAction.manual("Do it in Finder").isAutomatic == false)
    #expect(CleanAction.removeDirectory.isAutomatic)
}

@Suite struct DateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)!
    }

    @Test func countsMidnightsNotTwentyFourHourPeriods() {
        let now = date("2026-11-01T00:15:00")
        // Six hours ago, but on the previous day.
        #expect(Dates.describe(date("2026-10-31T18:00:00"), now: now, calendar: calendar)
            == "yesterday (Oct 31, 2026)")
        #expect(Dates.describe(date("2026-11-01T00:05:00"), now: now, calendar: calendar)
            == "today (Nov 1, 2026)")
        #expect(Dates.describe(date("2026-10-19T23:59:00"), now: now, calendar: calendar)
            == "13 days ago (Oct 19, 2026)")
    }
}

@Test func trashingIsAnAutomaticAction() {
    #expect(CleanAction.moveToTrash.isAutomatic)
}

@Test func readsCleanResultsWithoutTheTrashFlag() throws {
    let json = #"{"id":"/a","ok":true,"freedBytes":10}"#
    let result = try JSONDecoder().decode(CleanResult.self, from: Data(json.utf8))
    #expect(result.movedToTrash == false)
    #expect(result.freedBytes == 10)
}
