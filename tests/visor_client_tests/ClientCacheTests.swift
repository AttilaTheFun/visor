// A client's cache: what a sync brings is kept, and a session opened
// again — by a new connection, as after a relaunch — is there at once,
// with the place to sync from.

import MessageCache
@testable import VisorClient
import VisorProtocol
import XCTest

@MainActor
final class ClientCacheTests: XCTestCase {
    private func row(_ id: String, _ text: String, role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text)
    }

    private func transcript(_ rows: [TranscriptEntry], revision: Int, generation: Int, more: Bool = false) -> Envelope {
        var e = Envelope(type: "transcript")
        e.entries = rows; e.revision = revision; e.generation = generation; e.more = more
        return e
    }

    func testSessionOpensAsLastSeenAndSyncsFromThere() async throws {
        AgentServerConnection.cache = .inMemory()
        let config = AgentServerRecord(name: "Mac", address: "mac.example")

        // First look: nothing kept, so the view waits for the first sync.
        let first = AgentServerConnection(record: config)
        let opened = first.transcript(for: "S")
        XCTAssertFalse(opened.loaded)
        XCTAssertTrue(opened.entries.isEmpty)

        // The whole, then a delta: both kept, with the place reached.
        opened.sync(transcript([row("u1", "Hello", role: .user), row("a1", "Hi")], revision: 5, generation: 1, more: true))
        opened.sync(transcript([row("a2", "More")], revision: 6, generation: 1, more: true))
        XCTAssertEqual(opened.entries.map(\.id), ["u1", "a1", "a2"])
        let key = config.id + "/S"
        // Written off the main actor, in order.
        await AgentServerConnection.cacheQueue.drain()
        XCTAssertEqual(AgentServerConnection.cache.messages(in: key, limit: 10).messages.map(\.id), ["u1", "a1", "a2"])
        XCTAssertEqual(AgentServerConnection.cache.syncState(of: key), SyncState(revision: 6, generation: 1))

        // A rebuilt record replaces what was kept.
        opened.sync(transcript([row("u1", "Hello", role: .user), row("a1", "Hi, edited")], revision: 9, generation: 2))
        await AgentServerConnection.cacheQueue.drain()
        XCTAssertEqual(AgentServerConnection.cache.messages(in: key, limit: 10).messages.map(\.text), ["Hello", "Hi, edited"])

        // As after a relaunch: a new connection to the same computer has
        // the session at once, loaded, and knows where to sync from.
        let second = AgentServerConnection(record: config)
        let reopened = second.transcript(for: "S")
        XCTAssertTrue(reopened.loaded)
        XCTAssertEqual(reopened.entries.map(\.text), ["Hello", "Hi, edited"])
        XCTAssertEqual(reopened.revision, 9)
        XCTAssertEqual(reopened.generation, 2)
        XCTAssertFalse(reopened.hasEarlier)

        // Ending the session forgets it.
        second.end("S")
        await AgentServerConnection.cacheQueue.drain()
        XCTAssertEqual(AgentServerConnection.cache.count(in: key), 0)
        XCTAssertFalse(AgentServerConnection(record: config).transcript(for: "S").loaded)
    }
}
