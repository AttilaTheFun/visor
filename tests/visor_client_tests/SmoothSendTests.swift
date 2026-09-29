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

    /// A session resumed from here is shown as loaded, at revision 0,
    /// before the computer answers; the computer's first answer carries the
    /// resumed conversation whole, and may be at revision 0 as well.
    func testAResumedSessionTakesItsImportedRows() {
        let t = SessionTranscript()
        t.loaded = true
        var whole = transcript([user("a", "from the terminal")], revision: 0, generation: 42)
        whole.reset = true
        XCTAssertTrue(t.takes(whole))
        t.sync(whole)
        XCTAssertEqual(t.entries.map(\.id), ["a"])
        // Then the same answer again (the hold timed out) brings nothing.
        var same = transcript([], revision: 0, generation: 42)
        same.after = []
        XCTAssertFalse(t.takes(same))
    }

    func testADeltaPlacesRemovesAndMovesRows() {
        let t = SessionTranscript()
        t.sync(transcript([user("a", "one"), user("b", "two"), user("c", "three")], revision: 1, generation: 7))
        // b goes, x comes after a, and c (now after x) moves with it.
        var e = transcript([user("x", "new"), user("c", "three")], revision: 2, generation: 7)
        e.after = ["a", "x"]
        e.removed = ["b"]
        t.sync(e)
        XCTAssertEqual(t.entries.map(\.id), ["a", "x", "c"])

        // A row appended at the end, and one changed in place.
        var more = transcript([user("a", "one, edited"), user("d", "four")], revision: 3, generation: 7)
        more.after = ["", "c"]
        t.sync(more)
        XCTAssertEqual(t.entries.map(\.id), ["a", "x", "c", "d"])
        XCTAssertEqual(t.entries[0].text, "one, edited")

        // Another generation: the rows as a whole.
        t.sync(transcript([user("z", "fresh")], revision: 1, generation: 8))
        XCTAssertEqual(t.entries.map(\.id), ["z"])
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

/// A message sent to an idle agent is in the thread at once, and its copy
/// in the record takes its place under the same id; a slash command after
/// some words goes as its own message.
@MainActor
final class OptimisticSendTests: XCTestCase {
    func testTheRecordsCopyTakesTheSentRowsPlace() {
        let t = SessionTranscript()
        var whole = Envelope(type: "transcript")
        whole.entries = [TranscriptEntry(id: "a", role: .assistant, text: "Earlier")]
        whole.revision = 1; whole.generation = 1; whole.reset = true
        t.sync(whole)
        let sent = TranscriptEntry(id: "sending-1", role: .user, text: "Run the tests")
        var out = SessionTranscript.Outgoing(id: sent.id, entry: sent, sinceRevision: t.revision)
        out.shown = true
        t.sending.append(out)
        var delta = Envelope(type: "transcript")
        delta.entries = [TranscriptEntry(id: "user-file-9", role: .user, text: "Run the tests")]
        delta.after = ["a"]
        delta.revision = 2; delta.generation = 1
        t.sync(delta)
        XCTAssertTrue(t.sending.isEmpty)
        XCTAssertEqual(t.displayID(of: t.entries.last!), "sending-1", "shown under the sent row's id")
    }

    func testACommandAfterWordsIsItsOwnMessage() {
        let names: Set<String> = ["goal", "compact"]
        XCTAssertEqual(HostConnection.split("Here's the context.\n/goal Ship it\nwith tests", commands: names),
                       ["Here's the context.", "/goal Ship it\nwith tests"])
        XCTAssertEqual(HostConnection.split("/goal Ship it", commands: names), ["/goal Ship it"])
        // Not a command it knows, or not on a line of its own: words.
        XCTAssertEqual(HostConnection.split("See\n/usr/bin/env", commands: names), ["See\n/usr/bin/env"])
        XCTAssertEqual(HostConnection.split("Use /goal later", commands: names), ["Use /goal later"])
    }
}
