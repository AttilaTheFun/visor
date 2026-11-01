// A long session holds only its end in memory: past `heldRows` the oldest
// rows go, down to `servedRows`, without clients being told they were
// removed. The store has them, and pages before the first held come from
// it; a client too far behind for the rows held takes the latest whole.

import MessageCache
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class HeldRowsTests: ServerTestCase {
    private func line(_ type: String, _ uuid: String, _ parent: String?, _ text: String, id: String? = nil) -> String {
        let content: Any = type == "assistant" ? [["type": "text", "text": text]] : text
        var message: [String: Any] = ["role": type, "content": content]
        if let id { message["id"] = id }
        var o: [String: Any] = ["type": type, "uuid": uuid, "message": message, "timestamp": "2026-09-23T00:00:00Z"]
        if let parent { o["parentUuid"] = parent }
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    /// A session of 300 questions and answers, read into a store: its rows,
    /// and the record holding all of them as changes would.
    private func longSession() async throws -> (record: SessionRecord, rows: [TranscriptEntry]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-held-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        var lines: [String] = []
        var parent: String?
        for i in 0..<300 {
            lines.append(line("user", "u\(i)", parent, "Question \(i)"))
            lines.append(line("assistant", "a\(i)", "u\(i)", "Answer \(i)", id: "msg_\(i)"))
            parent = "a\(i)"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let indexer = SessionIndexer(store: try MessageCache.sqliteInMemory(), sessionID: "S", url: file, window: 600)
        var loaded: SessionIndexer.Loaded?
        for await event in indexer.events() {
            if case .loaded(let first) = event { loaded = first; break }
        }
        let rows = try XCTUnwrap(loaded).rows
        XCTAssertEqual(rows.count, 600)
        let record = SessionRecord(info: SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        record.indexer = indexer
        record.replaceEntriesForTesting(rows)
        return (record, rows)
    }

    func testTheOldestRowsGoWithoutBeingToldAsRemoved() async throws {
        let (record, rows) = try await longSession()
        let held = record.revision
        record.letGoOfOldRows()
        XCTAssertEqual(record.entries.map(\.id), rows.suffix(SessionRecord.servedRows).map(\.id))
        XCTAssertEqual(record.revision, held, "no change to the conversation")
        XCTAssertTrue(record.moreBefore)

        // A client up to date: nothing to take, nothing removed.
        let current = record.transcriptEnvelope(since: held)
        XCTAssertEqual(current.entries?.count, 0)
        XCTAssertEqual(current.removed ?? [], [])
        XCTAssertNil(current.reset)

        // A client from before the rows let go of were stamped: the latest,
        // as a whole, after the row the first of them follows.
        let behind = record.transcriptEnvelope(since: held - 1)
        XCTAssertEqual(behind.reset, true)
        XCTAssertEqual(behind.entries?.map(\.id), rows.suffix(SessionRecord.servedRows).map(\.id))
        XCTAssertEqual(behind.follows, rows[499].id)
        XCTAssertEqual(behind.more, true)

        // Before the first held: a page from the store.
        let page = await record.earlier(before: rows[500].id)
        XCTAssertEqual(page.entries?.map(\.id), rows[400..<500].map(\.id))
        XCTAssertEqual(page.more, true)
    }

    func testNothingGoesWithinTheBoundOrWithoutAStore() async throws {
        let (record, rows) = try await longSession()
        let indexer = record.indexer
        record.indexer = nil
        record.letGoOfOldRows()
        XCTAssertEqual(record.entries.count, 600, "only rows the store has go")

        record.indexer = indexer
        record.replaceEntriesForTesting(Array(rows.suffix(SessionRecord.heldRows)))
        record.letGoOfOldRows()
        XCTAssertEqual(record.entries.count, SessionRecord.heldRows)
    }

    func testWordsSentStillSettleAfterTheirEarlierCopiesGo() async throws {
        let (record, rows) = try await longSession()
        // "Question 0" went once before; sent again, and written after the
        // first went.
        record.unwritten = [(text: "Question 0", seen: 1)]
        record.letGoOfOldRows()
        XCTAssertEqual(record.unwritten.first?.seen, 0)
        XCTAssertFalse(record.entries.contains { $0.id == rows[0].id })
        _ = record.take(fileRow: TranscriptEntry(id: "again", role: .user, text: "Question 0"))
        XCTAssertTrue(record.unwritten.isEmpty, "the row written is the words sent")
    }
}
