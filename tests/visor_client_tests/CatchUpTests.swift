// A client that was away catches up a page at a time, each page a request
// of its own: the thread is told of the catch-up as a whole, not page by
// page, so it does not step through what it missed in front of the person.

@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class CatchUpTests: XCTestCase {
    private func page(_ ids: [String], revision: Int, later: Bool) -> Envelope {
        var e = Envelope(type: "transcript")
        e.entries = ids.map { TranscriptEntry(id: $0, role: .assistant, text: "row " + $0) }
        e.revision = revision
        e.generation = 1
        if later { e.later = true }
        return e
    }

    /// Waits, up to five seconds, for a condition.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// A thread opened and settled: no frame running.
    private func settled(frame: UInt64) async -> SessionTranscript {
        SessionTranscript.frame = frame
        let t = SessionTranscript()
        t.sync(page(["a"], revision: 1, later: false))
        await until { !t.inFrame }
        return t
    }

    func testACatchUpIsToldOnceWhenItsLastPageIsIn() async {
        let usual = SessionTranscript.frame
        defer { SessionTranscript.frame = usual }
        let t = await settled(frame: 2_000_000_000)
        let start = t.announced

        t.sync(page(["b", "c"], revision: 9, later: true))
        t.sync(page(["d", "e"], revision: 9, later: true))
        XCTAssertEqual(t.announced, start, "a page with more to follow was told")

        t.sync(page(["f"], revision: 9, later: false))
        XCTAssertEqual(t.announced, start + 1, "the catch-up was not told once its last page was in")
        XCTAssertEqual(t.entries.map(\.id), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(t.revision, 9)
    }

    func testALongCatchUpIsToldAtMostOnceAFrame() async {
        let usual = SessionTranscript.frame
        defer { SessionTranscript.frame = usual }
        let t = await settled(frame: 200_000_000)
        let start = t.announced
        let began = ContinuousClock.now

        t.sync(page(["b"], revision: 9, later: true))
        XCTAssertEqual(t.announced, start)
        // Still going after a frame: what is in so far is told then.
        await until { t.announced > start }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(200))
        XCTAssertEqual(t.announced, start + 1)

        // The last page right after: within half a frame of the last
        // telling, it waits for the frame's end rather than being told
        // twice in quick succession.
        t.sync(page(["c"], revision: 9, later: false))
        XCTAssertEqual(t.announced, start + 1)
        await until { t.announced > start + 1 }
        XCTAssertEqual(t.announced, start + 2)
        XCTAssertEqual(t.entries.map(\.id), ["a", "b", "c"])
    }
}
