// Earlier rows a page at a time: from this device's cache while it has
// them, from the server past that, the server's page kept on the device
// and shown a page at a time too. A page asked for twice is asked for once.

import MessageCache
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class EarlierPagesTests: XCTestCase {
    private var server: ScriptedServer!
    private var host: AgentServerConnection!
    private var key: String { host.record.id + "/S" }

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        server = ScriptedServer()
        ScriptedProvider.server = server
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
        host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
    }

    /// Until the main actor and the cache's queue have both done what
    /// was asked of them: a page read is asked for from a task, and its
    /// answer comes back to the main actor.
    private func settle() async {
        for _ in 0..<5 {
            for _ in 0..<20 { await Task.yield() }
            await AgentServerConnection.cacheQueue.drain()
        }
    }

    private func rows(_ prefix: String, _ count: Int) -> [TranscriptEntry] {
        (0..<count).map { TranscriptEntry(id: "\(prefix)\($0)", role: .assistant, text: "row \($0)") }
    }

    /// Kept on the device as a session last seen.
    private func keep(_ rows: [TranscriptEntry]) throws {
        try AgentServerConnection.cache.replace(key, with: rows)
        try AgentServerConnection.cache.setSyncState(SyncState(revision: 3, generation: 1), for: key)
    }

    private func earlier(_ rows: [TranscriptEntry], more: Bool) -> AgentServerEvent {
        var e = Envelope(type: "earlier")
        e.session = "S"
        e.entries = rows
        e.more = more
        return .session(e)
    }

    func testPagesComeFromTheCacheBeforeTheServer() async throws {
        try keep(rows("r", 900))
        let transcript = host.transcript(for: "S")
        XCTAssertEqual(transcript.entries.first?.id, "r300", "the last 600 shown")
        XCTAssertTrue(transcript.hasEarlier)

        host.loadEarlier("S")
        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(transcript.entries.first?.id, "r100", "one page of 200, asked for twice")
        XCTAssertEqual(transcript.entries.count, 800)
        XCTAssertTrue(server.earlierAsked.isEmpty, "the server is not asked while the cache has rows")

        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(transcript.entries.first?.id, "r0")
        XCTAssertTrue(transcript.hasEarlier, "the server may have rows before the cache's first")

        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(server.earlierAsked.map(\.before), ["r0"])
        server.deliver(earlier([], more: false))
        await settle()
        XCTAssertFalse(transcript.hasEarlier)
        XCTAssertEqual(transcript.entries.count, 900)
    }

    func testTheServersPageIsKeptAndShownAPageAtATime() async throws {
        try keep(rows("s", 10))
        let transcript = host.transcript(for: "S")
        XCTAssertFalse(transcript.hasEarlier)
        // The server says there are rows before its last ones.
        var delta = Envelope(type: "transcript")
        delta.entries = []
        delta.revision = 4
        delta.generation = 1
        delta.more = true
        transcript.sync(delta)
        XCTAssertTrue(transcript.hasEarlier)

        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(server.earlierAsked.map(\.before), ["s0"])
        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(server.earlierAsked.count, 1, "asked once while the page is on its way")

        server.deliver(earlier(rows("e", 500), more: true))
        await settle()
        XCTAssertEqual(transcript.entries.first?.id, "e300", "the last 200 of the server's page")
        XCTAssertEqual(transcript.entries.count, 210)
        XCTAssertTrue(transcript.hasEarlier)
        XCTAssertEqual(AgentServerConnection.cache.count(in: key), 510, "all of it kept")

        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(transcript.entries.first?.id, "e100", "the next page from the cache")
        XCTAssertEqual(server.earlierAsked.count, 1)

        // A delta after the start was reached does not bring the row back.
        host.loadEarlier("S")
        await settle()
        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(server.earlierAsked.map(\.before), ["s0", "e0"])
        server.deliver(earlier([], more: false))
        await settle()
        XCTAssertFalse(transcript.hasEarlier)
        delta.revision = 5
        transcript.sync(delta)
        XCTAssertFalse(transcript.hasEarlier, "the server's more is about its own last rows")
    }
}
