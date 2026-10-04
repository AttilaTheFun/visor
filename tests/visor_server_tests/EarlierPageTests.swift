// Rows before one a client has: from those the record holds, and past
// them from the session's cache — before the row asked about, wherever it
// is, so a client that has paged past the record's own rows gets the next
// page and not one it has already.

import MessageCache
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class EarlierPageTests: ServerTestCase {
    private func line(_ type: String, _ uuid: String, _ parent: String?, _ text: String, id: String? = nil) -> String {
        let content: Any = type == "assistant" ? [["type": "text", "text": text]] : text
        var message: [String: Any] = ["role": type, "content": content]
        if let id { message["id"] = id }
        var o: [String: Any] = ["type": type, "uuid": uuid, "message": message, "timestamp": "2026-09-23T00:00:00Z"]
        if let parent { o["parentUuid"] = parent }
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func testAPageBeforeARowPastTheRecordsOwn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-earlier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        var lines: [String] = []
        var parent: String?
        for i in 0..<30 {
            lines.append(line("user", "u\(i)", parent, "Question \(i)"))
            lines.append(line("assistant", "a\(i)", "u\(i)", "Answer \(i)", id: "msg_\(i)"))
            parent = "a\(i)"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let indexer = SessionIndexer(store: try MessageCache.sqliteInMemory(), sessionID: "S", url: file, window: 10)
        var loaded: SessionIndexer.Loaded?
        for await event in indexer.events() {
            if case .loaded(let first) = event { loaded = first; break }
        }
        let rows = try XCTUnwrap(loaded).rows
        let record = SessionRecord(info: SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: rows)
        record.indexer = indexer
        record.moreBefore = true

        // Before the record's first row: the 50 rows before it.
        let first = await record.earlier(before: rows[0].id)
        let older = try XCTUnwrap(first.entries)
        XCTAssertEqual(older.count, 50)
        XCTAssertEqual(first.more, false)

        // Before a row the record does not hold (a client paged that far):
        // the rows before that one, none of them ones it already has.
        let asked = older[20]
        let next = await record.earlier(before: asked.id)
        XCTAssertEqual(next.entries?.map(\.id), older[0..<20].map(\.id))
        XCTAssertEqual(next.more, false)

        // A row known nowhere: nothing, rather than some other page.
        let unknown = await record.earlier(before: "no-such-row")
        XCTAssertEqual(unknown.entries?.count, 0)
        XCTAssertEqual(unknown.more, false)
    }
}
