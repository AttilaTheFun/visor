// The reply being written ("responding", SessionTranscript+Responding):
// drawn from the stream until the client's own synced rows carry it, then
// the record's row in its place under the same id.

@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class RespondingTests: XCTestCase {
    private func rows(_ rows: [TranscriptEntry], revision: Int, generation: Int = 1, after: [String]? = nil) -> Envelope {
        var e = Envelope(type: "transcript")
        e.entries = rows; e.revision = revision; e.generation = generation; e.after = after
        return e
    }

    private func user(_ id: String, _ text: String) -> TranscriptEntry { TranscriptEntry(id: id, role: .user, text: text) }
    private func reply(_ id: String, _ text: String) -> TranscriptEntry { TranscriptEntry(id: id, role: .assistant, text: text) }

    private func session(_ type: String, _ fill: (inout Envelope) -> Void = { _ in }) -> Envelope {
        var e = Envelope(type: type)
        e.session = "s"
        fill(&e)
        return e
    }

    private func delta(_ id: String, _ text: String) -> Envelope { session("delta") { $0.id = id; $0.text = text } }
    private func busy(_ on: Bool) -> Envelope { session("busy") { $0.busy = on } }
    private func snapshot(_ streams: [StreamChunk], busy: Bool = true) -> Envelope {
        session("ephemeral") { $0.streams = streams; $0.busy = busy; $0.status = [] }
    }

    /// A transcript with its first rows synced and a turn under way.
    private func started() -> SessionTranscript {
        let t = SessionTranscript()
        t.sync(rows([user("u1", "Run the tests")], revision: 1))
        t.apply(busy(true))
        return t
    }

    private func drawn(_ t: SessionTranscript, ended: Bool = false) -> [String] {
        t.responding(ofEndedTurn: ended).map(\.text)
    }

    func testDeltasAppend() {
        let t = started()
        t.apply(delta("M", "Running"))
        t.apply(delta("M", " the tests"))
        XCTAssertEqual(drawn(t), ["Running the tests"])
        XCTAssertEqual(t.responding(ofEndedTurn: false).map(\.id), ["M"])
        XCTAssertEqual(t.responding(ofEndedTurn: false).first?.role, .assistant)
        XCTAssertTrue(t.writing)
        // A new message is a row of its own, after the first.
        t.apply(delta("N", "Next"))
        XCTAssertEqual(drawn(t), ["Running the tests", "Next"])
        XCTAssertEqual(t.shownIDs, ["u1", "M", "N"])
    }

    func testTheRowLandingReplacesItInPlaceUnderTheSameID() {
        let t = started()
        t.apply(delta("M", "All 42 pass"))
        XCTAssertEqual(t.shownIDs, ["u1", "M"])
        t.sync(rows([reply("M", "All 42 pass.")], revision: 2, after: ["u1"]))
        XCTAssertEqual(drawn(t), [])
        XCTAssertEqual(t.shownIDs, ["u1", "M"])
        XCTAssertEqual(t.displayID(of: t.entries.last!), "M")
        XCTAssertFalse(t.writing)
        // Words for it after its row are not drawn again.
        t.apply(delta("M", " late"))
        XCTAssertEqual(drawn(t), [])
        XCTAssertTrue(t.respondingHeld.isEmpty)
    }

    func testStreamEndOrTheTurnEndingBeforeTheRowKeepsIt() {
        let t = started()
        t.apply(delta("M", "Done."))
        t.apply(session("streamEnd") { $0.id = "M" })
        XCTAssertEqual(drawn(t), ["Done."])
        XCTAssertFalse(t.writing)
        t.apply(busy(false))
        // Still drawn, now as the ended turn's.
        XCTAssertEqual(drawn(t, ended: true), ["Done."])
        XCTAssertEqual(drawn(t), [])
        // A sync that does not bring it leaves it.
        t.sync(rows([reply("tool-1", "")], revision: 2, after: ["u1"]))
        XCTAssertEqual(drawn(t, ended: true), ["Done."])
        t.sync(rows([reply("M", "Done.")], revision: 3, after: ["tool-1"]))
        XCTAssertEqual(drawn(t, ended: true), [])
        XCTAssertEqual(t.shownIDs, ["u1", "tool-1", "M"])
    }

    func testASegmentedRowClearsIt() {
        let t = started()
        t.apply(delta("M", "First part, then a tool"))
        t.sync(rows([reply("M#2", "First part, then a tool")], revision: 2, after: ["u1"]))
        XCTAssertEqual(drawn(t), [])
        // The row is shown under the message's id: the stream's place.
        XCTAssertEqual(t.displayID(of: t.entries.last!), "M")
        XCTAssertEqual(t.shownIDs, ["u1", "M"])
    }

    func testANewTurnClearsOrphans() {
        let t = started()
        t.apply(delta("M", "Cut short"))
        t.apply(busy(false))
        XCTAssertEqual(drawn(t, ended: true), ["Cut short"])
        // The next message, sent to the idle agent, goes after it.
        let sent = TranscriptEntry(id: "sending-1", role: .user, text: "Again")
        var out = SessionTranscript.Outgoing(id: sent.id, entry: sent, sinceRevision: t.revision)
        out.shown = true
        t.sending.append(out)
        XCTAssertEqual(t.shownIDs, ["u1", "M", "sending-1"])
        // The turn begins: kept until a sync answers without it.
        t.apply(busy(true))
        XCTAssertEqual(drawn(t, ended: true), ["Cut short"])
        t.sync(rows([user("u2", "Again")], revision: 2, after: ["u1"]))
        XCTAssertEqual(drawn(t, ended: true), [])
        XCTAssertTrue(t.respondingHeld.isEmpty)
        XCTAssertEqual(t.shownIDs, ["u1", "sending-1"])
        // The new turn's words are drawn.
        t.apply(delta("N", "Again, then"))
        XCTAssertEqual(drawn(t), ["Again, then"])
    }

    func testAResubscribeSnapshotReplacesTheText() {
        let t = started()
        t.apply(delta("M", "Partial wor"))
        t.apply(snapshot([StreamChunk(id: "M", text: "Partial words, all of them so far")]))
        XCTAssertEqual(drawn(t), ["Partial words, all of them so far"])
        // Deltas go on from the snapshot.
        t.apply(delta("M", "."))
        XCTAssertEqual(drawn(t), ["Partial words, all of them so far."])
        // A snapshot without it (recorded on the server): kept until the
        // rows have it.
        t.apply(snapshot([]))
        XCTAssertEqual(drawn(t), ["Partial words, all of them so far."])
        XCTAssertFalse(t.writing)
        t.sync(rows([reply("M", "Partial words, all of them so far.")], revision: 2, after: ["u1"]))
        XCTAssertEqual(drawn(t), [])
        // One on subscribing that the rows already carry is not drawn.
        t.apply(snapshot([StreamChunk(id: "M", text: "Partial")]))
        XCTAssertEqual(drawn(t), [])
    }

    func testWordsAreToldOnTheirOwnFasterFrame() async throws {
        let usual = (SessionTranscript.frame, SessionTranscript.respondingFrame)
        SessionTranscript.frame = 2_000_000_000
        SessionTranscript.respondingFrame = 50_000_000
        defer { (SessionTranscript.frame, SessionTranscript.respondingFrame) = usual }
        let t = started()
        let rowsTold = t.announced
        t.apply(delta("M", "a"))
        XCTAssertEqual(t.respondingAnnounced, 1, "the first words at once")
        t.apply(delta("M", "b"))
        t.apply(delta("M", "c"))
        XCTAssertEqual(t.respondingAnnounced, 1, "the rest at the frame's end")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(t.respondingAnnounced, 2)
        XCTAssertEqual(drawn(t), ["abc"])
        // The rows' frame was not told for the words.
        XCTAssertEqual(t.announced, rowsTold)
    }
}
