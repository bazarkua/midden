import Foundation
import Testing
@testable import MiddenCore

@Test func safetyOrdersFromSafeToInfo() {
    #expect(Safety.allCases.sorted() == [.safe, .review, .info])
}

@Test func manualActionsAreNotAutomatic() {
    #expect(CleanAction.manual("Do it in Finder").isAutomatic == false)
    #expect(CleanAction.removeDirectory.isAutomatic)
}
