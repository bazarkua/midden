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
