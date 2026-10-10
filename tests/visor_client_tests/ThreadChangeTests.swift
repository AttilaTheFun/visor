// What the connection log says of a sync: nothing for rows added at the
// end or changed in place; the rest — taken whole, rows gone or come in
// between, rows shown twice — said.

@testable import VisorClient
import XCTest

final class ThreadChangeTests: XCTestCase {
    private func change(_ before: [String], _ after: [String], whole: Bool = false) -> ThreadChange? {
        ThreadChange(before: before, after: after, whole: whole, generation: (1, 1), revision: (4, 5))
    }

    func testRowsAddedAtTheEndAreOfNoNote() {
        XCTAssertNil(change(["a", "b"], ["a", "b", "c", "d"]))
        XCTAssertNil(change(["a", "b"], ["a", "b"]), "changed in place")
    }

    func testAnAnswerTakenWholeIsNoted() {
        let noted = change(["a", "b"], ["a", "b"], whole: true)
        XCTAssertEqual(noted?.description, "taken whole, revision 4 → 5, rows 2 → 2")
    }

    func testRowsThatWentOrCameInBetweenAreNoted() {
        // The top of the thread dropped, and a row in its middle replaced
        // by one under another id: the list lays those out again.
        let noted = change(["a", "b", "c", "d"], ["b", "x", "d", "e"])
        XCTAssertEqual(noted?.went, 2)
        XCTAssertEqual(noted?.cameInBetween, 1)
        XCTAssertEqual(noted?.description, "a delta, revision 4 → 5, rows 4 → 4, 2 went, 1 came in between")
    }

    func testRowsShownTwiceAreNoted() {
        XCTAssertEqual(change(["a", "b"], ["a", "b", "b"])?.duplicates, 1)
    }
}
