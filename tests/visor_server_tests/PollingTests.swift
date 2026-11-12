// What a client gets without the live channel: the list of sessions and a
// session's state, each held until it changes; the rows before one and an
// acknowledgement over REST; and the API under whatever path a front
// mounted it.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class PollingTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-polling-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    /// A GET, answered when the server answers it.
    private func get(_ path: String) async -> Envelope? {
        let request = HTTPRequest(method: "GET", path: path, headers: ["authorization": "Bearer pw"], body: "")
        let text: String = await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0.body) } }
        return Envelope.decode(text)
    }

    /// A GET on its way: what it answers, once it does.
    private func getLater(_ path: String) -> Task<Envelope?, Never> {
        Task { await get(path) }
    }

    @Test func testTheListIsHeldUntilItChanges() async throws {
        server.sessions = [record("A")]
        let got = await get("/api/sessions")
        let first = try #require(got)
        #expect(first.type == "welcome")
        #expect((first.sessions?.map(\.id)) == ["A"])
        let revision = try #require(first.revision)

        let held = getLater("/api/sessions?since=\(revision)")
        await Task.yield()
        #expect(server.sessionsWaiters.count == 1, "held while nothing changed")
        server.sessions.append(record("B"))
        server.broadcastSessions()
        let answered = await held.value
        let next = try #require(answered)
        #expect((next.sessions?.map(\.id)) == ["A", "B"])
        #expect(next.revision == (revision + 1))
        // An old revision is answered at once.
        let again = await get("/api/sessions?since=\(revision)")
        #expect((again?.revision) == (revision + 1))
    }

    @Test func testASessionsStateIsHeldUntilItChanges() async throws {
        let session = record("A")
        server.sessions = [session]
        let got = await get("/api/sessions/A/state")
        let first = try #require(got)
        #expect(first.type == "ephemeral")
        #expect(first.busy == false)
        let revision = try #require(first.revision)

        let held = getLater("/api/sessions/A/state?since=\(revision)")
        await Task.yield()
        #expect((server.stateWaiters["A"]?.count) == 1)
        server.handle(.busy(true), from: session)
        server.handle(.activity("Thinking…"), from: session)
        let answered = await held.value
        let next = try #require(answered)
        #expect(next.busy == true)
        #expect((try #require(next.revision)) > revision)
        // The latest, with everything since: the activity too.
        let latest = await get("/api/sessions/A/state")
        #expect((latest?.activity) == "Thinking…")

        // Acknowledging a notice over REST moves the state on.
        session.notice = "Forked elsewhere"
        server.stateChanged(session)
        let noticed = await get("/api/sessions/A/state")
        #expect((noticed?.notice) == "Forked elsewhere")
        let ack = HTTPRequest(method: "POST", path: "/api/sessions/A/acknowledge", headers: ["authorization": "Bearer pw"], body: "{}")
        _ = server.route(ack)
        #expect(session.notice == nil)
        let acknowledged = await get("/api/sessions/A/state")
        #expect((acknowledged?.notice) == nil)

        // A session that ends answers those holding, with 404.
        let current = try #require(acknowledged?.revision)
        let holding = getLater("/api/sessions/A/state?since=\(current)")
        await Task.yield()
        server.perform(.end(session: "A"), from: nil)
        let ended = await holding.value
        #expect(ended == nil, "a 404 is not an envelope")
    }

    @Test func testEarlierRowsAndAnyMountPath() async throws {
        let session = SessionRecord(info: SessionInfo(id: "A", agent: .claude, cwd: "/tmp", title: "A", created: 0),
                                    process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                                    entries: (0..<5).map { TranscriptEntry(id: "r\($0)", role: .user, text: "row \($0)") })
        server.sessions = [session]
        let earlier = await get("/api/sessions/A/earlier?before=r3")
        #expect((earlier?.type) == "earlier")
        #expect((earlier?.entries?.map(\.id)) == ["r0", "r1", "r2"])
        // A front that forwards its mount path whole.
        let mounted = await get("/visor/api/sessions")
        #expect((mounted?.type) == "welcome")
        let mountedEarlier = await get("/visor/api/sessions/A/earlier?before=r1")
        #expect((mountedEarlier?.entries?.map(\.id)) == ["r0"])
        #expect(VisorServer.apiPath("/visor/api/sessions/A/state") == "/sessions/A/state")
        #expect(VisorServer.apiPath("/sessions") == "/sessions")
    }
}
}
