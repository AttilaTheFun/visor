// The cache behaves the same whatever holds it: rows by place, appended,
// prepended, replaced, dropped by source; states kept; words found.

import MessageCache
import VisorProtocol
import XCTest

final class MessageCacheTests: XCTestCase {
    private func row(_ id: String, _ text: String, role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text, activities: ["Bash: ls"], images: ["/tmp/x.png"], imageSizes: [ImageSize(width: 4, height: 3)])
    }

    private func exercise(_ cache: MessageCache) throws {
        // Ingest from a source, in file order, with nodes.
        let state = SourceState(path: "/p", identity: "1", bytes: 10, nextSeq: 3)
        try cache.resetSource("S", state: SourceState(path: "/p", identity: "1", bytes: 0, nextSeq: 0))
        try cache.ingest("S", nodes: [SourceNode(seq: 0, key: "u1", parentKey: nil, kind: "user", isPrompt: true),
                                     SourceNode(seq: 1, key: "a1", parentKey: "u1", kind: "assistant", isPrompt: false)],
                         messages: [PlacedMessage(message: row("u1", "Hello pelican", role: .user), seq: 0, sourceKey: "u1"),
                                    PlacedMessage(message: row("a1", "Hi there, pelican fan"), seq: 1, sourceKey: "a1")],
                         state: state)
        XCTAssertEqual(cache.sourceState(of: "S"), state)
        XCTAssertEqual(cache.nodes(in: "S").map(\.key), ["u1", "a1"])
        XCTAssertEqual(cache.count(in: "S"), 2)
        // A row rewritten keeps its place and its whole shape.
        try cache.ingest("S", nodes: [], messages: [PlacedMessage(message: row("a1", "Hi there, pelican fan, edited"), seq: 9, sourceKey: "a1")], state: state)
        let page = cache.messages(in: "S", limit: 10)
        XCTAssertEqual(page.messages.map(\.text), ["Hello pelican", "Hi there, pelican fan, edited"])
        XCTAssertEqual(page.messages.last?.imageSizes.first?.width, 4)
        XCTAssertEqual(page.messages.last?.activities, ["Bash: ls"])
        XCTAssertFalse(page.more)
        // Appended after, prepended before, paged by place.
        try cache.append("S", [row("a2", "Later")])
        try cache.prepend("S", [row("z0", "Earlier still"), row("z1", "Earlier")])
        let all = cache.messages(in: "S", limit: 10).messages.map(\.id)
        XCTAssertEqual(all, ["z0", "z1", "u1", "a1", "a2"])
        let before = cache.messages(in: "S", limit: 2, before: cache.seq(of: "u1", in: "S"))
        XCTAssertEqual(before.messages.map(\.id), ["z0", "z1"])
        XCTAssertFalse(before.more)
        let lastTwo = cache.messages(in: "S", limit: 2)
        XCTAssertEqual(lastTwo.messages.map(\.id), ["a1", "a2"])
        XCTAssertTrue(lastTwo.more)
        // Rows by source line dropped (a fork's abandoned lines).
        try cache.removeMessages(in: "S", sourceKeys: ["a1"])
        XCTAssertEqual(cache.messages(in: "S", limit: 10).messages.map(\.id), ["z0", "z1", "u1", "a2"])
        // Words found, each required.
        XCTAssertEqual(cache.search("pelican").map(\.messageID), ["u1"])
        XCTAssertTrue(cache.search("pelican walrus").isEmpty)
        XCTAssertTrue(cache.search("\"pelican\" OR").isEmpty)
        // Sync state kept; a replace stands in whole.
        try cache.setSyncState(SyncState(revision: 7, generation: 2), for: "S")
        XCTAssertEqual(cache.syncState(of: "S"), SyncState(revision: 7, generation: 2))
        try cache.replace("S", with: [row("r1", "One"), row("r2", "Two")])
        XCTAssertEqual(cache.messages(in: "S", limit: 10).messages.map(\.id), ["r1", "r2"])
        try cache.remove("S")
        XCTAssertEqual(cache.count(in: "S"), 0)
        XCTAssertNil(cache.syncState(of: "S"))
    }

    func testMemoryStorage() throws { try exercise(MessageCache.inMemory()) }
    func testSQLiteStorage() throws { try exercise(try MessageCache.sqliteInMemory()) }
}
