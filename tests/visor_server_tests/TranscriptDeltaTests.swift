// Every change to a transcript can be sent as a delta: rows new, changed
// or moved since a revision, each with the row it follows, and the rows
// removed since. The whole is only for a client whose generation differs.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class TranscriptDeltaTests {
    init() { TestPlatform.install() }

    private func row(_ id: String, _ text: String = "") -> TranscriptEntry { TranscriptEntry(id: id, role: .assistant, text: text.isEmpty ? id : text) }

    @Test func testRemovalsAndInsertsAreDeltas() {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                              entries: [row("a"), row("b"), row("c")])
        let generation = r.generation
        let before = r.revision

        // A row goes and one comes in the middle: the same generation.
        r.replaceEntriesForTesting([row("a"), row("x"), row("c")])
        #expect(r.generation == generation)
        let delta = r.rows(since: before)
        #expect(delta.removed == ["b"])
        // x is new after a; c now follows x.
        #expect(delta.rows.map(\.id) == ["x", "c"])
        #expect(delta.after == ["a", "x"])

        // A change in place is only that row.
        let mid = r.revision
        r.replaceEntriesForTesting([row("a"), row("x", "edited"), row("c")])
        #expect((r.rows(since: mid).rows.map(\.id)) == ["x"])
        #expect(r.rows(since: mid).removed == [])

        // It survives the wire.
        let decoded = Envelope.decode(r.transcriptEnvelope(since: before).encoded())
        #expect((decoded?.after) == ["a", "x"])
        #expect((decoded?.removed) == ["b"])
    }

    /// A client far behind is brought up a page at a time, in order, with
    /// nothing skipped however many rows came in: what went is said with
    /// the first page, and `later` until the last.
    @Test func testAClientFarBehindCatchesUpAPageAtATime() {
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
            #expect((page?.entries?.count ?? 0) <= SessionRecord.pageRows)
            #expect((page?.removed ?? []) == (pages == 1 ? ["old2"] : []))
            got += page?.entries?.map(\.id) ?? []
            guard page?.later == true else { break }
            after = page?.entries?.last?.id
        }
        #expect(pages == 3)
        #expect(got == added.map(\.id))
    }

    /// The first answer is the latest rows, not the whole thread; a page
    /// of earlier rows is a page.
    @Test func testTheFirstAnswerAndAnEarlierPageAreSmall() async {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let rows = (0..<300).map { row("r\($0)") }
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: rows)
        let whole = r.transcriptEnvelope(since: nil)
        #expect((whole.entries?.count) == SessionRecord.servedRows)
        #expect((whole.entries?.last?.id) == "r299")
        #expect(whole.more == true)
        #expect(whole.follows == "r199", "the row its first follows: a client keeping it keeps what is before")
        let earlier = await r.earlier(before: "r200")
        #expect((earlier.entries?.map(\.id)) == ((200 - SessionRecord.pageRows..<200).map { "r\($0)" }))
        #expect(earlier.more == true)
    }
}
}
