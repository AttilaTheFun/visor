// A server that asks for its messages to be held in memory only: what this
// device kept of its sessions goes at the sign-in that says so, nothing more
// is written, and the rows let go of come from the server again.

import MessageCache
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class MessagesInMemoryTests: XCTestCase {
    private var server: ScriptedServer!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        server = ScriptedServer()
        server.identity = ServerIdentity(id: "mac", addresses: [], keepMessages: false)
        ScriptedProvider.server = server
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
    }

    private func connection(keepMessages: Bool) -> AgentServerConnection {
        AgentServerConnection(record: AgentServerRecord(id: "M", name: "", address: "mac.example", provider: "scripted",
                                                        keepMessages: keepMessages))
    }

    /// Until the main actor and the cache's queue have both done what was
    /// asked of them.
    private func settle() async {
        for _ in 0..<5 {
            for _ in 0..<20 { await Task.yield() }
            await AgentServerConnection.cacheQueue.drain()
        }
    }

    private func rows(_ prefix: String, _ count: Int) -> [TranscriptEntry] {
        (0..<count).map { TranscriptEntry(id: "\(prefix)\($0)", role: .assistant, text: "row \($0)") }
    }

    func testWhatWasKeptGoesAtTheSignInThatSaysSo() async throws {
        let cache = AgentServerConnection.cache
        try cache.replace("M/S", with: rows("r", 50))
        try cache.setSyncState(SyncState(revision: 3, generation: 1), for: "M/S")
        let host = connection(keepMessages: true)
        let transcript = host.transcript(for: "S")
        XCTAssertEqual(transcript.entries.count, 50, "opened as last seen, before the server has said")

        host.connect()
        await settle()
        XCTAssertFalse(host.record.keepMessages, "the record says so from now on")
        XCTAssertEqual(cache.count(in: "M/S"), 0, "what this device kept of it is gone")
        XCTAssertNil(cache.syncState(of: "M/S"))
        XCTAssertEqual(transcript.entries.count, 50, "the rows on screen stay")

        var delta = Envelope(type: "transcript")
        delta.entries = rows("r", 52)
        delta.revision = 4
        delta.generation = 1
        transcript.sync(delta)
        await settle()
        XCTAssertEqual(cache.count(in: "M/S"), 0, "and nothing more is written")
    }

    func testRowsLetGoOfComeFromTheServerAgain() async throws {
        let host = connection(keepMessages: false)
        host.connect()
        await settle()
        let transcript = host.transcript(for: "S")
        var delta = Envelope(type: "transcript")
        delta.entries = rows("r", 600)
        delta.revision = 4
        delta.generation = 1
        transcript.sync(delta)
        XCTAssertEqual(transcript.letGo(above: "r550", keeping: 400), 150)

        host.loadEarlier("S")
        await settle()
        XCTAssertEqual(server.earlierAsked.map(\.before), ["r150"], "asked of the server: there is no cache to read")
        var page = Envelope(type: "earlier")
        page.session = "S"
        page.entries = rows("r", 150)
        page.more = false
        server.deliver(.session(page))
        await settle()
        XCTAssertEqual(transcript.entries.first?.id, "r50", "a page of 100 put back in")
        XCTAssertEqual(AgentServerConnection.cache.count(in: "M/S"), 0, "and not kept on disk")
    }
}
