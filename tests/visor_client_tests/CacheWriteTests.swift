// What a sync writes to the device's cache: every row synced or paged to
// stays kept — a change is written as a change, never the rows in memory
// in place of the history — so a thread reads back offline as far as it
// was seen. A client behind catches up a page at a time; a session left is
// let go of, and read back from the cache when it is opened again.

import MessageCache
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class CacheWriteTests: XCTestCase {
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

    private func settle() async {
        for _ in 0..<5 {
            for _ in 0..<20 { await Task.yield() }
            await AgentServerConnection.cacheQueue.drain()
        }
    }

    private func rows(_ prefix: String, _ range: Range<Int>) -> [TranscriptEntry] {
        range.map { TranscriptEntry(id: "\(prefix)\($0)", role: .assistant, text: "row \($0)") }
    }

    private var kept: [String] { AgentServerConnection.cache.messages(in: key, limit: 1 << 20).messages.map(\.id) }

    /// A session last seen at revision 3, generation 1, its 300 rows kept.
    private func open() throws -> SessionTranscript {
        try AgentServerConnection.cache.replace(key, with: rows("r", 0..<300))
        try AgentServerConnection.cache.setSyncState(SyncState(revision: 3, generation: 1), for: key)
        let transcript = host.transcript(for: "S")
        XCTAssertEqual(transcript.entries.count, AgentServerConnection.initialRows)
        return transcript
    }

    private func delta(_ entries: [TranscriptEntry], after: [String], removed: [String] = [], revision: Int, later: Bool = false) -> Envelope {
        var e = Envelope(type: "transcript")
        e.entries = entries; e.after = after; e.removed = removed
        e.revision = revision; e.generation = 1
        if later { e.later = true }
        return e
    }

    func testAStructuralChangeKeepsTheHistoryBeforeIt() async throws {
        let transcript = try open()
        // r298 goes; x comes in after r296.
        transcript.sync(delta([TranscriptEntry(id: "x", role: .assistant, text: "x")], after: ["r296"], removed: ["r298"], revision: 4))
        await settle()
        XCTAssertEqual(Array(transcript.entries.suffix(4).map(\.id)), ["r296", "x", "r297", "r299"])
        XCTAssertEqual(kept.count, 300, "the 200 rows before the window are still kept")
        XCTAssertEqual(Array(kept.prefix(2)), ["r0", "r1"])
        XCTAssertEqual(Array(kept.suffix(4)), ["r296", "x", "r297", "r299"])
    }

    /// A row changed before the rows held (the row it follows not among
    /// them) changes where it is kept, and isn't put at the end, where it
    /// would stay below every row that came after it.
    func testARowChangedBeforeTheRowsHeldStaysInItsPlace() async throws {
        let transcript = try open()
        transcript.sync(delta([TranscriptEntry(id: "r150", role: .assistant, text: "changed"),
                               TranscriptEntry(id: "r200", role: .assistant, text: "first held, changed"),
                               TranscriptEntry(id: "gone", role: .assistant, text: "never kept")],
                              after: ["r149", "r199", "elsewhere"], revision: 4))
        await settle()
        XCTAssertEqual(transcript.entries.map(\.id), rows("r", 200..<300).map(\.id), "nothing moved to the end")
        XCTAssertEqual(transcript.entries.first?.text, "first held, changed")
        XCTAssertEqual(kept, rows("r", 0..<300).map(\.id), "kept in order, and nothing not kept added")
        let changed = AgentServerConnection.cache.messages(in: key, limit: 1 << 20).messages.first { $0.id == "r150" }
        XCTAssertEqual(changed?.text, "changed")

        // What comes after goes at the end, here and in the cache.
        transcript.sync(delta([TranscriptEntry(id: "sent", role: .user, text: "hi")], after: ["r299"], revision: 5))
        await settle()
        XCTAssertEqual(transcript.entries.last?.id, "sent")
        XCTAssertEqual(kept.last, "sent")
    }

    /// A cache an earlier build left a row misplaced in (at the end) is
    /// synced whole once: the session is shown as kept, asked for in no
    /// generation of the server's, and the whole puts the rows in order.
    func testACacheAnEarlierBuildMisplacedARowInIsSyncedWholeOnce() async throws {
        let cache = MessageCache.inMemory()
        var misplaced = rows("r", 0..<300)
        misplaced.append(misplaced.remove(at: 250))
        try cache.replace(key, with: misplaced)
        try cache.setSyncState(SyncState(revision: 3, generation: 1), for: key)
        AgentServerConnection.cache = cache
        let transcript = host.transcript(for: "S")
        XCTAssertEqual(transcript.entries.last?.id, "r250", "shown as kept until the server answers")
        XCTAssertEqual(transcript.generation, -1)

        var whole = Envelope(type: "transcript")
        whole.entries = rows("r", 200..<300)
        whole.reset = true; whole.revision = 3; whole.generation = 1; whole.more = true
        whole.follows = "r199"
        transcript.sync(whole)
        await settle()
        XCTAssertEqual(transcript.entries.map(\.id), rows("r", 200..<300).map(\.id))
        XCTAssertEqual(kept, rows("r", 0..<300).map(\.id))
        XCTAssertEqual(cache.syncState(of: key), SyncState(revision: 3, generation: 1))

        // Once: a cache mended already syncs on as before.
        AgentServerConnection.cache = cache
        XCTAssertEqual(cache.syncState(of: key)?.generation, 1)
    }

    func testANewGenerationCarriesOnFromTheRowItFollows() async throws {
        let transcript = try open()
        // The server started again: the whole, its last rows, after r249.
        var whole = Envelope(type: "transcript")
        whole.entries = rows("r", 250..<300) + [TranscriptEntry(id: "n", role: .assistant, text: "new")]
        whole.reset = true; whole.revision = 1; whole.generation = 2; whole.more = true
        whole.follows = "r249"
        transcript.sync(whole)
        await settle()
        XCTAssertEqual(kept.count, 301, "the history before r250 kept")
        XCTAssertEqual(kept.first, "r0")
        XCTAssertEqual(kept.last, "n")
        XCTAssertEqual(transcript.entries.first?.id, "r200", "the rows held before it stay too")
        XCTAssertEqual(transcript.generation, 2)

        // One whose row is not kept is the history: nothing to carry on.
        whole.entries = rows("z", 0..<3); whole.follows = "elsewhere"; whole.generation = 3
        transcript.sync(whole)
        await settle()
        XCTAssertEqual(kept, ["z0", "z1", "z2"])
    }

    func testAClientBehindCatchesUpAPageAtATimeAndHoldsItsRevisionUntilTheLast() async throws {
        let transcript = try open()
        transcript.sync(delta(rows("a", 0..<50), after: ["r299"] + rows("a", 0..<49).map(\.id), revision: 20, later: true))
        XCTAssertEqual(transcript.revision, 3, "held where it was until the last page")
        XCTAssertEqual(transcript.catchUp, SessionTranscript.CatchUp(since: 3, after: "a49", revision: 20))
        transcript.sync(delta(rows("a", 50..<60), after: rows("a", 49..<59).map(\.id), revision: 22))
        await settle()
        XCTAssertNil(transcript.catchUp)
        XCTAssertEqual(transcript.revision, 20, "the revision the catching up began at: what changed since comes next")
        XCTAssertEqual(transcript.entries.last?.id, "a59")
        XCTAssertEqual(kept.count, 360)
        XCTAssertEqual(AgentServerConnection.cache.syncState(of: key)?.revision, 20)
    }

    func testALeftSessionLetsGoOfItsRowsAndReadsThemBack() async throws {
        let transcript = try open()
        host.subscribe("S")
        await settle()
        host.leave("S")
        host.release("S")
        XCTAssertTrue(transcript.entries.isEmpty)
        XCTAssertTrue(transcript.released)
        XCTAssertEqual(server.unsubscribed, ["S"])
        // A screen opened on it asks for its transcript first: the rows are
        // there before the screen appears (no "Loading…" on the way back).
        XCTAssertTrue(host.transcript(for: "S") === transcript)
        XCTAssertTrue(transcript.loaded)
        XCTAssertEqual(transcript.entries.last?.id, "r299")
        host.subscribe("S")
        await settle()
        XCTAssertFalse(transcript.released)
        XCTAssertEqual(transcript.entries.count, AgentServerConnection.initialRows)
        XCTAssertEqual(transcript.entries.last?.id, "r299")
        XCTAssertEqual(transcript.revision, 3)
    }

    /// A screen built again appears before the one it replaces goes: the
    /// session is still shown, and is not let go of. Nor is the one the app
    /// says is on screen; and one let go of all the same is taken up again
    /// by the screen that finds it so.
    func testASessionStillShownIsNotLetGoOf() async throws {
        let transcript = try open()
        host.subscribe("S")
        host.subscribe("S")
        host.leave("S")
        host.release("S")
        XCTAssertFalse(transcript.released, "the new screen shows it")
        XCTAssertEqual(transcript.entries.count, AgentServerConnection.initialRows)

        host.leave("S")
        VisorNotificationHandler.shared.viewing = NotificationTarget(computer: host.record.address, session: "S")
        host.release("S")
        XCTAssertFalse(transcript.released, "the session the app is showing")
        VisorNotificationHandler.shared.viewing = nil

        host.release("S")
        XCTAssertTrue(transcript.released)
        host.takeUp("S")
        await settle()
        XCTAssertFalse(transcript.released)
        XCTAssertEqual(transcript.entries.count, AgentServerConnection.initialRows)
    }
}
