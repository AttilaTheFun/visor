// A session pinned to the top of its computer's list, or unpinned: the
// session's own, kept with it in sessions.json and sent with it, so every
// client lists the same. Pins are ordered by when they were made, the
// first on top: an unpin and a pin again moves a session to the last of
// them. Archiving takes the pin; an archived session isn't pinned.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that does nothing.
@MainActor
private final class IdleAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, emit) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func startsTurn(_ text: String) -> Bool { true }
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

extension ServerTests {
@Suite @MainActor final class SessionPinsTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-pins-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7959)
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0), process: IdleAgent(), entries: [])
    }

    /// The pinned ones, first pinned first, as a client lists them.
    private var pinned: [String] {
        server.sessions.filter { $0.info.pinnedAt != nil }.sorted { $0.info.pinnedAt! < $1.info.pinnedAt! }.map(\.info.id)
    }

    /// Each pin goes after those made before it, even in the same moment
    /// or with the clock set back; an unpin and a pin again puts it last.
    @Test func testPinsAreInTheOrderTheyWereMade() {
        let (a, b, c) = (record("a"), record("b"), record("c"))
        server.sessions = [a, b, c]
        #expect(a.info.pinnedAt == nil && a.info.json["pinnedAt"] == .null, "not pinned, and nothing said of it")
        server.perform(.pin(session: "b"), from: nil)
        server.perform(.pin(session: "a"), from: nil)
        server.perform(.pin(session: "c"), from: nil)
        #expect(pinned == ["b", "a", "c"])

        // Pinned again: where it is it stays.
        let at = b.info.pinnedAt
        server.perform(.pin(session: "b"), from: nil)
        #expect(b.info.pinnedAt == at)

        server.perform(.unpin(session: "b"), from: nil)
        #expect(b.info.pinnedAt == nil)
        #expect(pinned == ["a", "c"])
        server.perform(.pin(session: "b"), from: nil)
        #expect(pinned == ["a", "c", "b"], "re-pinned: the last of them")

        // A clock behind the latest pin still makes the next one later.
        let latest = server.sessions.compactMap(\.info.pinnedAt).max()!
        #expect(server.nextPin(now: latest - 3600) > latest)
        #expect(server.nextPin(now: latest + 60) == latest + 60)
    }

    /// The pin is the session's: in its info on the wire, kept in the
    /// store, and set over REST as over the socket.
    @Test func testThePinIsTheSessionsAndKept() throws {
        server.password = "pw"
        let session = record("s")
        server.sessions = [session]
        // A session from before pins, or from an older server.
        let older = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"o","title":"Old"}"#.utf8))
        #expect(older.pinnedAt == nil)

        let answer = server.route(HTTPRequest(method: "POST", path: "/api/sessions/s/pin", headers: ["authorization": "Bearer pw"], body: "{}"))
        #expect(answer.status == 200)
        let reply = try #require(Envelope.decode(answer.body))
        let at = try #require(session.info.pinnedAt)
        #expect(reply.sessions?.first?.pinnedAt == at, "the answer carries the session pinned")
        #expect(session.info.json["pinnedAt"].double == at)
        #expect(SessionInfo(json: session.info.json)?.pinnedAt == at, "every client reads it")

        // Written down with the session, and read back.
        let stored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session.stored))
        #expect(stored.info.pinnedAt == at)

        // Unpinned over REST.
        let unpinned = server.route(HTTPRequest(method: "POST", path: "/api/sessions/s/unpin", headers: ["authorization": "Bearer pw"], body: "{}"))
        #expect(unpinned.status == 200)
        #expect(session.info.pinnedAt == nil)
        #expect(Envelope.decode(unpinned.body)?.sessions?.first?.pinnedAt == nil)

        // The socket's envelopes, as they go.
        #expect(Envelope.decode(Envelope.pin(session: "s").encoded())?.type == "pin")
        #expect(Envelope.decode(Envelope.unpin(session: "s").encoded())?.session == "s")
    }

    /// `hello` says the server keeps pins: what a client offers Pin by.
    @Test func testHelloSaysItKeepsPins() throws {
        server.password = "pw"
        let answer = server.route(HTTPRequest(method: "GET", path: "/api/hello", headers: ["authorization": "Bearer pw"], body: ""))
        #expect(answer.status == 200)
        #expect(Envelope.decode(answer.body)?.pins == true)
        #expect(Envelope.decode(#"{"type":"hello"}"#)?.pins == nil, "a server before pins says nothing")
    }

    /// Archiving takes the pin; an archived session isn't pinned.
    @Test func testAnArchivedSessionIsNotPinned() {
        let session = record("s")
        server.sessions = [session]
        server.perform(.pin(session: "s"), from: nil)
        #expect(session.info.pinnedAt != nil)
        server.perform(Envelope.archive(session: "s"), from: nil)
        #expect(session.info.archived)
        #expect(session.info.pinnedAt == nil, "off the top of the list it has left")
        server.perform(.pin(session: "s"), from: nil)
        #expect(session.info.pinnedAt == nil, "not while archived")
        server.perform(Envelope.unarchive(session: "s"), from: nil)
        #expect(session.info.pinnedAt == nil, "back among the rest")
    }
}
}
