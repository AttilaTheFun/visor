// A server followed without its live channel: where the host has no
// socket service, or the socket never opens, the connection still comes
// up — the list of sessions from `GET /sessions`, each session's state
// from `GET /sessions/<id>/state`, both asked for again as they are
// answered — and says it is polling. The socket is tried again later and
// takes over when it opens.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// HTTP as a Visor server answers it, with a list and a state that the
/// test moves on.
@MainActor
final class PollingHTTP: VisorHTTPService {
    var sessions: [SessionInfo] = [SessionInfo(id: "s1", agent: .claude, cwd: "/tmp", title: "One", created: 0)]
    var listRevision = 3
    var state = Envelope.ephemeral(session: "s1", streams: [], status: [], activity: nil, busy: false, approval: nil, queued: [], notice: nil)
    var stateRevision = 7
    private(set) var asked: [String] = []
    /// Polls held for the next change, by the path asked.
    private var held: [(path: String, resume: CheckedContinuation<String, Error>)] = []

    nonisolated func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await answer(method: method, url: url)
    }

    private func answer(method: String, url: String) async throws -> String {
        // The path below the mount, however the address mounted it.
        let path = url.range(of: "/api/").map { "/api/" + url[$0.upperBound...] } ?? url
        asked.append(method + " " + path)
        if path.hasSuffix("/api/hello") { return Envelope.hello(host: "Polled Mac", login: "", token: "tok-1").encoded() }
        if path.hasPrefix("/api/sessions/s1/state") {
            if path.hasSuffix("since=\(stateRevision)") { return try await hold(path) }
            var e = state; e.revision = stateRevision; return e.encoded()
        }
        if path.hasPrefix("/api/sessions/s1/transcript") { return try await hold(path) }
        if path.hasPrefix("/api/sessions/s1/commands") { var e = Envelope(type: "commands"); e.commands = []; return e.encoded() }
        if path.hasPrefix("/api/sessions") {
            if path.hasSuffix("since=\(listRevision)") { return try await hold(path) }
            var e = Envelope.welcome(host: "Polled Mac", sessions: sessions, catalogs: []); e.revision = listRevision; return e.encoded()
        }
        return Envelope(type: "reply").encoded()
    }

    private func hold(_ path: String) async throws -> String {
        try await withCheckedThrowingContinuation { held.append((path, $0)) }
    }

    private var listAnswer: String {
        var e = Envelope.welcome(host: "Polled Mac", sessions: sessions, catalogs: []); e.revision = listRevision; return e.encoded()
    }

    private var stateAnswer: String {
        var e = state; e.revision = stateRevision; return e.encoded()
    }

    /// The list changed: those holding for it are answered with it.
    func changeList(_ sessions: [SessionInfo]) {
        self.sessions = sessions
        listRevision += 1
        release("/api/sessions?", with: listAnswer)
    }

    func changeState(_ state: Envelope) {
        self.state = state
        stateRevision += 1
        release("/api/sessions/s1/state", with: stateAnswer)
    }

    private func release(_ prefix: String, with answer: String) {
        let now = held.filter { $0.path.hasPrefix(prefix) }
        held.removeAll { $0.path.hasPrefix(prefix) }
        for item in now { item.resume.resume(returning: answer) }
    }

    nonisolated func status(of error: Error) -> Int? { nil }
}

@MainActor
final class PollingFallbackTests: XCTestCase {
    private var http: PollingHTTP!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        VisorHost.settings = MemorySettings()
        http = PollingHTTP()
        VisorHost.http = http
        VisorHost.socket = nil
    }

    private func settle(_ rounds: Int = 60) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    /// Lets the breath between one answer and the next ask pass (a host
    /// without a socket service paces it by the clock).
    private func breathe() async {
        try? await Task.sleep(nanoseconds: UInt64(VisorAgentServer.pollBreath + 200) * 1_000_000)
        await settle()
    }

    /// No socket service at all: connected by polling from the start,
    /// the list and a subscribed session's state following each change.
    func testAHostWithoutSocketsFollowsByPolling() async throws {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "https://proxy.example/visor"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertFalse(host.live)
        XCTAssertEqual(host.record.name, "Polled Mac")
        XCTAssertEqual(host.sessions.map(\.id), ["s1"])
        XCTAssertTrue(http.asked.contains("GET /api/hello"))
        await breathe()
        XCTAssertTrue(http.asked.contains("GET /api/sessions?since=3"), "held for the next change: \(http.asked)")

        host.subscribe("s1")
        await breathe()
        XCTAssertTrue(http.asked.contains { $0.hasPrefix("GET /api/sessions/s1/state") }, "\(http.asked)")
        var working = http.state
        working.busy = true
        working.activity = "Thinking…"
        http.changeState(working)
        await breathe()
        XCTAssertEqual(host.transcripts["s1"]?.busy, true)
        XCTAssertEqual(host.transcripts["s1"]?.activity, "Thinking…")

        var two = http.sessions
        two.append(SessionInfo(id: "s2", agent: .codex, cwd: "/tmp", title: "Two", created: 1))
        http.changeList(two)
        await breathe()
        XCTAssertEqual(host.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(host.state, .connected)
    }

    /// A socket that never opens (a path with no WebSocket): after the
    /// login's time, polling takes over, and the socket is tried again
    /// after a while.
    func testASocketThatNeverOpensGivesWayToPolling() async throws {
        let socket = ScriptedSocket()
        socket.opens = false
        VisorHost.socket = socket
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connecting)
        XCTAssertEqual(socket.opened, ["wss://mac.example/"])
        socket.elapse(VisorAgentServer.loginTimeout)
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertFalse(host.live)
        XCTAssertEqual(host.sessions.map(\.id), ["s1"])

        // Later, the socket again: this time it opens, and the channel's
        // own welcome takes over.
        socket.opens = true
        socket.elapse(VisorAgentServer.socketRetryInterval)
        await settle()
        XCTAssertEqual(socket.opened.count, 2)
        XCTAssertEqual(host.state, .connected)
        XCTAssertTrue(host.live)
    }
}
