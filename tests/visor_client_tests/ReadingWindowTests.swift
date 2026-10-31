// A long thread keeps only so many rows in memory: once the reader stops,
// rows more than four pages above the first one on screen are let go of,
// and the thread says it has earlier rows again, so they come back a page
// at a time from the cache (or the server) if the reader goes back to them.

@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class ReadingWindowTests: XCTestCase {
    private func thread(_ count: Int) -> SessionTranscript {
        let t = SessionTranscript()
        t.entries = (0..<count).map { TranscriptEntry(id: "r\($0)", role: .assistant, text: "row \($0)") }
        t.reachedStart = true
        t.hasEarlier = false
        return t
    }

    func testRowsFarAboveTheScreenAreLetGoOf() {
        let t = thread(1000)
        XCTAssertEqual(t.letGo(above: "r900", keeping: 400), 500)
        XCTAssertEqual(t.entries.first?.id, "r500", "four pages kept above the first row on screen")
        XCTAssertEqual(t.entries.last?.id, "r999", "everything below it kept")
        XCTAssertTrue(t.hasEarlier, "the rows let go of are there to load again")
        XCTAssertFalse(t.reachedStart)
    }

    func testNothingGoesWithinTheWindowOrForARowNotHeld() {
        let t = thread(300)
        XCTAssertEqual(t.letGo(above: "r250", keeping: 400), 0)
        XCTAssertEqual(t.letGo(above: "elsewhere", keeping: 400), 0)
        XCTAssertEqual(t.entries.count, 300)
        XCTAssertFalse(t.hasEarlier)
    }

    func testNothingGoesWhileAPageIsOnItsWay() {
        let t = thread(1000)
        t.loadingEarlier = true
        XCTAssertEqual(t.letGo(above: "r900", keeping: 400), 0)
        XCTAssertEqual(t.entries.count, 1000)
    }

    func testTheReaderGoingBackGetsTheRowsAgainInFront() {
        let t = thread(1000)
        t.letGo(above: "r900", keeping: 400)
        let page = (400..<500).map { TranscriptEntry(id: "r\($0)", role: .assistant, text: "row \($0)") }
        XCTAssertEqual(t.putEarlier(page, more: true), 100)
        XCTAssertEqual(t.entries.first?.id, "r400")
        XCTAssertEqual(t.entries.count, 600)
    }
}
