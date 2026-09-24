// The cache: built from a session's file, kept up as it grows, thrown
// away and rebuilt, paged by place, searched by words; and a fork's
// abandoned lines make no rows.

import ClaudeTranscript
import MessageCache
import VisorProtocol
@testable import VisorServer
import XCTest

final class TranscriptStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private var store: MessageCache!
    /// Held: an indexer released is a watcher gone.
    private var follower: SessionIndexer?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-store-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("s.jsonl")
        store = try MessageCache.sqliteInMemory()
    }

    private func line(_ type: String, _ uuid: String, _ parent: String?, _ text: String, id: String? = nil) -> String {
        let content: Any = type == "assistant" ? [["type": "text", "text": text]] : text
        var message: [String: Any] = ["role": type, "content": content]
        if let id { message["id"] = id }
        var o: [String: Any] = ["type": type, "uuid": uuid, "message": message, "timestamp": "2026-09-23T00:00:00Z"]
        if let parent { o["parentUuid"] = parent }
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func load(_ indexer: SessionIndexer) async -> SessionIndexer.Loaded {
        await withCheckedContinuation { c in
            indexer.start(onLoaded: { c.resume(returning: $0) }, onLines: { _ in })
        }
    }

    func testBuildsPagesRebuildsAndSearches() async throws {
        var lines: [String] = []
        var parent: String? = nil
        for i in 0..<30 {
            let u = "u\(i)", a = "a\(i)"
            lines.append(line("user", u, parent, "Question number \(i) about pelicans"))
            lines.append(line("assistant", a, u, "Answer \(i): the pelican count is \(i * 7)", id: "msg_\(i)"))
            parent = a
        }
        try write(lines)
        let indexer = SessionIndexer(store: store, sessionID: "S", url: file, window: 10)
        let loaded = await load(indexer)
        XCTAssertEqual(loaded.rows.count, 10)
        XCTAssertTrue(loaded.more)
        XCTAssertEqual(loaded.rows.last?.text, "Answer 29: the pelican count is 203")
        XCTAssertEqual(loaded.prompts.count, 30)
        XCTAssertEqual(store.count(in: "S"), 60)

        // Paged by place, oldest first, until there is no more.
        let page: ([TranscriptEntry], Bool) = await withCheckedContinuation { c in
            indexer.earlier(before: loaded.rows.first!.id, limit: 10) { c.resume(returning: ($0, $1)) }
        }
        XCTAssertEqual(page.0.count, 10)
        XCTAssertTrue(page.1)
        XCTAssertEqual(page.0.last?.id, "msg_24")

        // Words found across the cache.
        let hits = store.search("pelican 203")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.messageID, "msg_29")
        XCTAssertTrue(store.search("walrus").isEmpty)

        // The file grows: the cache follows from where it stopped.
        indexer.stop()
        let grown: [SessionIndexer.Line] = await withCheckedContinuation { c in
            let follower = SessionIndexer(store: store, sessionID: "S", url: file, window: 10)
            self.follower = follower
            follower.start(onLoaded: { second in
                XCTAssertEqual(second.rows.count, 10)
                if let h = try? FileHandle(forWritingTo: self.file) {
                    h.seekToEndOfFile()
                    h.write((self.line("user", "u30", "a29", "One more") + "\n" + self.line("assistant", "a30", "u30", "Last answer", id: "msg_30") + "\n").data(using: .utf8)!)
                    try? h.close()
                }
            }, onLines: { c.resume(returning: $0) })
        }
        XCTAssertEqual(grown.compactMap { $0.rows.first?.text }, ["One more", "Last answer"])
        XCTAssertEqual(store.count(in: "S"), 62)
        XCTAssertEqual(store.sourceState(of: "S")?.nextSeq, 62)
        follower?.stop()

        // Thrown away: rebuilt from the file alone, the same.
        let fresh = try MessageCache.sqliteInMemory()
        let rebuilt = await load(SessionIndexer(store: fresh, sessionID: "S", url: file, window: 100))
        XCTAssertEqual(rebuilt.rows.count, 62)
        XCTAssertEqual(rebuilt.rows.last?.text, "Last answer")
    }

    private func boundary(_ uuid: String) -> String {
        let o: [String: Any] = ["type": "system", "subtype": "compact_boundary", "uuid": uuid, "timestamp": "2026-09-23T00:00:00Z"]
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func testCompactionKeepsTheHistoryAndAForkAfterItIsStillAFork() async throws {
        try write([
            line("user", "u1", nil, "First"),
            line("assistant", "a1", "u1", "Reply one", id: "m1"),
            boundary("b1"),
            line("user", "u2", "b1", "After compaction"),
            line("assistant", "a2", "u2", "Reply two", id: "m2"),
            line("user", "u3", "a2", "Old branch"),
            line("assistant", "a3", "u3", "Old reply", id: "m3"),
            line("user", "u4", "a2", "New branch"),
            line("assistant", "a4", "u4", "New reply", id: "m4"),
        ])
        let loaded = await load(SessionIndexer(store: store, sessionID: "C", url: file, window: 100))
        XCTAssertEqual(loaded.rows.map(\.text), ["First", "Reply one", "After compaction", "Reply two", "New branch", "New reply"])
        XCTAssertEqual(loaded.abandonedPrompts, 1)
        XCTAssertEqual(loaded.prompts, ["u1", "u2", "u4"])
    }

    func testForkLeavesAbandonedLinesOutOfRows() async throws {
        try write([
            line("user", "u1", nil, "First"),
            line("assistant", "a1", "u1", "Reply one", id: "m1"),
            line("user", "u2", "a1", "Old branch question"),
            line("assistant", "a2", "u2", "Old branch reply", id: "m2"),
            // Resumed elsewhere from a1: the file's last line is on this branch.
            line("user", "u3", "a1", "New branch question"),
            line("assistant", "a3", "u3", "New branch reply", id: "m3"),
        ])
        let loaded = await load(SessionIndexer(store: store, sessionID: "F", url: file, window: 100))
        XCTAssertEqual(loaded.rows.map(\.text), ["First", "Reply one", "New branch question", "New branch reply"])
        XCTAssertEqual(loaded.abandonedPrompts, 1)
        XCTAssertTrue(loaded.abandoned.contains("u2"))
        XCTAssertEqual(store.count(in: "F"), 4)
    }
}
