// Every change to a transcript can be sent as a delta: rows new, changed
// or moved since a revision, each with the row it follows, and the rows
// removed since. The whole is only for a client whose generation differs.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class TranscriptDeltaTests: ServerTestCase {
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

    /// A client far behind is brought up a page at a time, in order, with
    /// nothing skipped however many rows came in: what went is said with
    /// the first page, and `later` until the last.
    func testAClientFarBehindCatchesUpAPageAtATime() {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let first = (0..<3).map { row("old\($0)") }
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: first)
        let since = r.revision
        let added = (0..<250).map { row("new\($0)") }
        r.replaceEntriesForTesting(Array(first.dropLast()) + added)

        var got: [String] = []
        var after: String?
        var pages = 0
        while true {
            let page = Envelope.decode(r.transcriptEnvelope(since: since, after: after).encoded())
            pages += 1
            XCTAssertLessThanOrEqual(page?.entries?.count ?? 0, SessionRecord.pageRows)
            XCTAssertEqual(page?.removed ?? [], pages == 1 ? ["old2"] : [])
            got += page?.entries?.map(\.id) ?? []
            guard page?.later == true else { break }
            after = page?.entries?.last?.id
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(got, added.map(\.id))
    }

    /// The first answer is the latest rows, not the whole thread; a page
    /// of earlier rows is a page.
    func testTheFirstAnswerAndAnEarlierPageAreSmall() async {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let rows = (0..<300).map { row("r\($0)") }
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: rows)
        let whole = r.transcriptEnvelope(since: nil)
        XCTAssertEqual(whole.entries?.count, SessionRecord.servedRows)
        XCTAssertEqual(whole.entries?.last?.id, "r299")
        XCTAssertEqual(whole.more, true)
        XCTAssertEqual(whole.follows, "r199", "the row its first follows: a client keeping it keeps what is before")
        let earlier = await r.earlier(before: "r200")
        XCTAssertEqual(earlier.entries?.map(\.id), (200 - SessionRecord.pageRows..<200).map { "r\($0)" })
        XCTAssertEqual(earlier.more, true)
    }
}
