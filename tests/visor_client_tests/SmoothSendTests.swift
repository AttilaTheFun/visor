// Sending a message sets off a burst of changes. A message keeps one
// identity through its copies, so the view sees one row change rather than
// rows removed and inserted; and views are told of the burst a frame at a
// time, not change by change.

import MessageCache
@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class SmoothSendTests: XCTestCase {
    private func transcript(_ rows: [TranscriptEntry], revision: Int, generation: Int) -> Envelope {
        var e = Envelope(type: "transcript")
        e.entries = rows; e.revision = revision; e.generation = generation
        return e
    }

    private func user(_ id: String, _ text: String) -> TranscriptEntry { TranscriptEntry(id: id, role: .user, text: text) }

    func testASentMessageKeepsOneIdentityThroughItsCopies() {
        let t = SessionTranscript()
        t.sync(transcript([user("u-old", "earlier")], revision: 1, generation: 1))

        // Sent from here: shown at once under its own id.
        let sent = TranscriptEntry(id: "sending-abc", role: .user, text: "Run the tests")
        t.sending.append(.init(id: sent.id, entry: sent, sinceRevision: t.revision))

        // The computer's copy arrives: the sent row goes, the record's row
        // is shown under the sent row's id.
        t.sync(transcript([user("user-1-x", "Run the tests")], revision: 2, generation: 1))
        XCTAssertTrue(t.sending.isEmpty)
        XCTAssertEqual(t.displayID(of: t.entries.last!), "sending-abc")

        // The agent's own record replaces it under another id, in a
        // rebuilt set of rows: the same identity carries over.
        t.sync(transcript([user("u-old", "earlier"), user("user-file-9f", "Run the tests ")], revision: 3, generation: 2))
        XCTAssertEqual(t.entries.map(\.id), ["u-old", "user-file-9f"])
        XCTAssertEqual(t.displayID(of: t.entries[1]), "sending-abc")
        // A row that stayed keeps its own id.
        XCTAssertEqual(t.displayID(of: t.entries[0]), "u-old")
    }

    /// Waits, up to five seconds, for a condition.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testABurstIsToldAFrameAtATime() async {
        SessionTranscript.frame = 60_000_000
        defer { SessionTranscript.frame = 500_000_000 }
        let t = SessionTranscript()
        let start = t.announced

        // A burst: the first change is told at once, the rest wait.
        t.busy = true
        t.activity = "Thinking…"
        t.error = "one"
        t.error = "two"
        XCTAssertEqual(t.announced - start, 1)

        // The frame ends: the rest are told together, once. (Waited for,
        // not slept: a busy machine runs the frame late.)
        await until { t.announced - start == 2 }
        XCTAssertEqual(t.announced - start, 2)

        // Nothing more changed: the next frame ends with nothing to tell.
        await until { !t.inFrame }
        XCTAssertEqual(t.announced - start, 2)

        // A send mid-frame is told at once.
        t.busy = false
        XCTAssertEqual(t.announced - start, 3)
        t.error = "x"
        t.flush()
        XCTAssertEqual(t.announced - start, 4)
    }
}
