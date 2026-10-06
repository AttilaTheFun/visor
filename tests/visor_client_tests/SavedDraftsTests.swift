// A draft is kept as it is typed, per computer and session, and gone
// once sent.

@testable import VisorClient
import VisorServices
import XCTest

@MainActor
final class SavedDraftsTests: XCTestCase {
    func testADraftIsKeptPerSessionUntilSent() {
        VisorHost.settings = MemorySettings()
        SavedDrafts.keep("half a thought", server: "mac", session: "s1")
        SavedDrafts.keep("another", server: "mac", session: "s2")
        XCTAssertEqual(SavedDrafts.draft(server: "mac", session: "s1"), "half a thought")
        XCTAssertEqual(SavedDrafts.draft(server: "mac", session: "s2"), "another")
        XCTAssertEqual(SavedDrafts.draft(server: "other", session: "s1"), "")
        SavedDrafts.clear(server: "mac", session: "s1")
        XCTAssertEqual(SavedDrafts.draft(server: "mac", session: "s1"), "")
        XCTAssertEqual(SavedDrafts.draft(server: "mac", session: "s2"), "another")
    }
}
