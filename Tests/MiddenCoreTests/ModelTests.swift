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

@Test func manualActionsAreNotAutomatic() {
    #expect(CleanAction.manual("Do it in Finder").isAutomatic == false)
    #expect(CleanAction.removeDirectory.isAutomatic)
}
