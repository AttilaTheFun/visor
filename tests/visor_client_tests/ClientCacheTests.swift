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

    func testSessionOpensAsLastSeenAndSyncsFromThere() throws {
        HostConnection.cache = .inMemory()
        let config = HostConfig(name: "Mac", host: "mac.example", password: "")

        // First look: nothing kept, so the view waits for the first sync.
        let first = HostConnection(config: config)
        let opened = first.transcript(for: "S")
        XCTAssertFalse(opened.loaded)
        XCTAssertTrue(opened.entries.isEmpty)

        // The whole, then a delta: both kept, with the place reached.
        opened.sync(transcript([row("u1", "Hello", role: .user), row("a1", "Hi")], revision: 5, generation: 1, more: true))
        opened.sync(transcript([row("a2", "More")], revision: 6, generation: 1, more: true))
        XCTAssertEqual(opened.entries.map(\.id), ["u1", "a1", "a2"])
        let key = config.id + "/S"
        XCTAssertEqual(HostConnection.cache.messages(in: key, limit: 10).messages.map(\.id), ["u1", "a1", "a2"])
        XCTAssertEqual(HostConnection.cache.syncState(of: key), SyncState(revision: 6, generation: 1))

        // A rebuilt record replaces what was kept.
        opened.sync(transcript([row("u1", "Hello", role: .user), row("a1", "Hi, edited")], revision: 9, generation: 2))
        XCTAssertEqual(HostConnection.cache.messages(in: key, limit: 10).messages.map(\.text), ["Hello", "Hi, edited"])

        // As after a relaunch: a new connection to the same computer has
        // the session at once, loaded, and knows where to sync from.
        let second = HostConnection(config: config)
        let reopened = second.transcript(for: "S")
        XCTAssertTrue(reopened.loaded)
        XCTAssertEqual(reopened.entries.map(\.text), ["Hello", "Hi, edited"])
        XCTAssertEqual(reopened.revision, 9)
        XCTAssertEqual(reopened.generation, 2)
        XCTAssertFalse(reopened.hasEarlier)

        // Ending the session forgets it.
        second.end("S")
        XCTAssertEqual(HostConnection.cache.count(in: key), 0)
        XCTAssertFalse(HostConnection(config: config).transcript(for: "S").loaded)
    }
}
