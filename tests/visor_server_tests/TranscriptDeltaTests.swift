// Every change to a transcript can be sent as a delta: rows new, changed
// or moved since a revision, each with the row it follows, and the rows
// removed since. The whole is only for a client whose generation differs.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class TranscriptDeltaTests: XCTestCase {
    private func row(_ id: String, _ text: String = "") -> TranscriptEntry { TranscriptEntry(id: id, role: .assistant, text: text.isEmpty ? id : text) }

    func testRemovalsAndInsertsAreDeltas() {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                              entries: [row("a"), row("b"), row("c")])
        let generation = r.generation
        let before = r.revision

        // A row goes and one comes in the middle: the same generation.
        r.replaceEntriesForTesting([row("a"), row("x"), row("c")])
        XCTAssertEqual(r.generation, generation)
        let delta = r.rows(since: before)
        XCTAssertEqual(delta.removed, ["b"])
        // x is new after a; c now follows x.
        XCTAssertEqual(delta.rows.map(\.id), ["x", "c"])
        XCTAssertEqual(delta.after, ["a", "x"])

        // A change in place is only that row.
        let mid = r.revision
        r.replaceEntriesForTesting([row("a"), row("x", "edited"), row("c")])
        XCTAssertEqual(r.rows(since: mid).rows.map(\.id), ["x"])
        XCTAssertEqual(r.rows(since: mid).removed, [])

        // It survives the wire.
        let decoded = Envelope.decode(r.transcriptEnvelope(since: before).encoded())
        XCTAssertEqual(decoded?.after, ["a", "x"])
        XCTAssertEqual(decoded?.removed, ["b"])
    }
}
