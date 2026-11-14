import Foundation
// The cache behaves the same whatever holds it: rows by place, appended,
// prepended, replaced, dropped by source; states kept; words found.

import MessageCache
import VisorProtocol
import Synchronization
import Testing

@Suite final class MessageCacheTests {
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
        #expect(cache.sourceState(of: "S") == state)
        #expect((cache.nodes(in: "S").map(\.key)) == ["u1", "a1"])
        #expect(cache.count(in: "S") == 2)
        // A row rewritten keeps its place and its whole shape.
        try cache.ingest("S", nodes: [], messages: [PlacedMessage(message: row("a1", "Hi there, pelican fan, edited"), seq: 9, sourceKey: "a1")], state: state)
        let page = cache.messages(in: "S", limit: 10)
        #expect(page.messages.map(\.text) == ["Hello pelican", "Hi there, pelican fan, edited"])
        #expect((page.messages.last?.imageSizes.first?.width) == 4)
        #expect((page.messages.last?.activities) == ["Bash: ls"])
        #expect(!page.more)
        // Appended after, prepended before, paged by place.
        try cache.append("S", [row("a2", "Later")])
        try cache.prepend("S", [row("z0", "Earlier still"), row("z1", "Earlier")])
        let all = cache.messages(in: "S", limit: 10).messages.map(\.id)
        #expect(all == ["z0", "z1", "u1", "a1", "a2"])
        let before = cache.messages(in: "S", limit: 2, before: cache.seq(of: "u1", in: "S"))
        #expect(before.messages.map(\.id) == ["z0", "z1"])
        #expect(!before.more)
        let lastTwo = cache.messages(in: "S", limit: 2)
        #expect(lastTwo.messages.map(\.id) == ["a1", "a2"])
        #expect(lastTwo.more)
        // Rows by source line dropped (a fork's abandoned lines).
        try cache.removeMessages(in: "S", sourceKeys: ["a1"])
        #expect((cache.messages(in: "S", limit: 10).messages.map(\.id)) == ["z0", "z1", "u1", "a2"])
        // Words found, each required.
        #expect((cache.search("pelican").map(\.messageID)) == ["u1"])
        #expect(cache.search("pelican walrus").isEmpty)
        #expect(cache.search("\"pelican\" OR").isEmpty)
        // A row kept changes where it is; one not kept stays out.
        try cache.update("S", [row("u1", "Hello pelican, changed", role: .user), row("nowhere", "Not kept")])
        #expect((cache.messages(in: "S", limit: 10).messages.map(\.id)) == ["z0", "z1", "u1", "a2"])
        #expect((cache.messages(in: "S", limit: 10).messages[2].text) == "Hello pelican, changed")
        #expect((cache.search("changed").map(\.messageID)) == ["u1"])
        // Every session synced whole, once for each reason: its generation
        // forgotten, its revision and rows kept.
        try cache.setSyncState(SyncState(revision: 7, generation: 2), for: "S")
        cache.resyncAll(once: "a test")
        #expect(cache.syncState(of: "S") == SyncState(revision: 7, generation: -1))
        #expect(cache.count(in: "S") == 4)
        try cache.setSyncState(SyncState(revision: 8, generation: 2), for: "S")
        cache.resyncAll(once: "a test")
        #expect((cache.syncState(of: "S")?.generation) == 2, "once")
        // Sync state kept; a replace stands in whole.
        try cache.setSyncState(SyncState(revision: 7, generation: 2), for: "S")
        #expect(cache.syncState(of: "S") == SyncState(revision: 7, generation: 2))
        try cache.replace("S", with: [row("r1", "One"), row("r2", "Two")])
        #expect((cache.messages(in: "S", limit: 10).messages.map(\.id)) == ["r1", "r2"])
        try cache.remove("S")
        #expect(cache.count(in: "S") == 0)
        #expect(cache.syncState(of: "S") == nil)
    }

    @Test func testMemoryStorage() throws { try exercise(MessageCache.inMemory()) }
    @Test func testSQLiteStorage() throws { try exercise(try MessageCache.sqliteInMemory()) }
}

/// A host that supplies its own storage gets it from `open(named:)`. One
/// test at a time: both set MessageCache's process-wide storage, and one
/// opening a cache while the other's provider is set was asked of it.
@Suite(.serialized) final class StorageProviderTests {
    /// A cache in a file, in the folder a host names, is there for the
    /// next open: what a client reads its threads from offline.
    @Test func testAFileInTheHostsFolderKeepsItsRows() throws {
        let folder = NSTemporaryDirectory() + "visor-cache-" + String(UInt64.random(in: 0...UInt64.max))
        MessageCache.directory = folder
        defer {
            MessageCache.directory = nil
            try? FileManager.default.removeItem(atPath: folder)
        }
        let rows = (0..<5).map { TranscriptEntry(id: "r\($0)", role: .assistant, text: "row \($0) of the pelican thread") }
        try MessageCache.open(named: "kept").append("S", rows)
        #expect(FileManager.default.fileExists(atPath: folder + "/kept.sqlite"))
        let again = MessageCache.open(named: "kept")
        #expect((again.messages(in: "S", limit: 3).messages.map(\.id)) == ["r2", "r3", "r4"])
        #expect(again.search("pelican").count == 5)
    }

    @Test func testOpenUsesTheSuppliedStorage() {
        let asked = Mutex<[String]>([])
        MessageCache.storageProvider = { name in
            asked.withLock { $0.append(name) }
            guard name == "mine" else { return nil }
            // The host's own storage, with what it already holds.
            let storage = MemoryStorage()
            try? storage.insertMessage("s", TranscriptEntry(id: "kept", role: .user, text: "hi"), seq: 0)
            return storage
        }
        defer { MessageCache.storageProvider = nil }
        let cache = MessageCache.open(named: "mine")
        #expect((cache.messages(in: "s", limit: 10).messages.map(\.id)) == ["kept"])
        #expect((asked.withLock { $0 }) == ["mine"])
    }
}

/// The latest mark a session's state is kept by, found in the cache.
@Suite final class LastMessageTests {
    @Test func testTheLatestMatchingRow() throws {
        for cache in [try MessageCache.sqliteInMemory(), MessageCache(storage: MemoryStorage())] {
            try cache.append("s", [TranscriptEntry(id: "goal-file-1", role: .tool, text: "One", toolName: "goal"),
                                   TranscriptEntry(id: "a", role: .assistant, text: "Working"),
                                   TranscriptEntry(id: "u", role: .user, text: "/goal clear"),
                                   TranscriptEntry(id: "b", role: .assistant, text: "Done")])
            #expect((cache.lastMessage(in: "s", idPrefixes: ["goal-file-"])?.id) == "goal-file-1")
            #expect((cache.lastMessage(in: "s", idPrefixes: ["goal-file-"], userTexts: ["/goal clear"])?.id) == "u")
            #expect(cache.lastMessage(in: "s", idPrefixes: ["loop-file-"]) == nil)
        }
    }
}
