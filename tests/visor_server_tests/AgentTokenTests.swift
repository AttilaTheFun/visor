// Each session's agent holds a token of its own: one session's can't ask,
// or answer an approval, as another's; the shared token of builds before
// 0.60 is taken only from a session whose agent such a build left under
// its host, and only while that agent runs; and a session's token is the
// same from launch to launch.

import AgentHostWire
import Foundation
import Synchronization
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

/// A host that answers as visor-agent-host does: hello, then whatever the
/// test has it say.
private final class FakeHostStream: ByteStream, Sendable {
    private let heard = Mutex<(@MainActor (Data?) -> Void)?>(nil)
    var localAddress: String? { nil }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {
        heard.withLock { $0 = chunk }
        // After attach is waiting for it, as a real host's hello comes.
        Task { @MainActor in
            chunk(AgentHostFrame.hello(AgentHostHello(host: 2, agent: 3, oldest: 0, next: 0)).encoded)
        }
    }

    func send(_ data: Data, sent: (@MainActor () -> Void)?) { sent?() }
    func close() {}

    /// The agent under the host ends.
    @MainActor func agentEnds() {
        let chunk = heard.withLock { $0 }
        chunk?(AgentHostFrame.exited(status: 0, signaled: false).encoded)
    }
}

private struct FakeHosting: AgentHosting {
    let stream: FakeHostStream
    var program: String { "visor-agent-host" }
    func problem() -> String? { nil }
    @MainActor func connect(_ path: String) async -> (any ByteStream)? { stream }
}

extension ServerTests {
@Suite @MainActor final class AgentTokenTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-token-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        // Never the real keychain.
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        server.sessions = [record("A", "One"), record("B", "Two")]
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String, _ title: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    private func ask(from caller: String, token: String) -> Envelope {
        var e = Envelope(type: "agent")
        e.token = token
        e.client = caller
        e.mode = "sessions"
        e.id = "r1"
        return server.agentReply(e)
    }

    private func approval(for session: String, token: String) {
        var e = Envelope(type: "approval_request")
        e.token = token
        e.session = session
        e.id = "r1"
        e.text = "Bash"
        e.prompt = "ls"
        server.handle(e, from: ClientConnection(stream: FakeHostStream()))
    }

    private func rest(_ bearer: String) -> Int {
        server.route(HTTPRequest(method: "GET", path: "/api/sessions", headers: ["authorization": "Bearer " + bearer], body: "")).status
    }

    /// The agent of `record`, left under its host by an earlier launch,
    /// picked up as this launch does.
    private func pickUp(_ record: SessionRecord, ownToken: Bool?) async -> FakeHostStream {
        let stream = FakeHostStream()
        ServerPlatform.current.agentHosts = FakeHosting(stream: stream)
        await server.pickUp(record, host: StoredHost(socket: "/tmp/vh-test.sock", line: 0, carried: nil, ownToken: ownToken),
                            agentPID: nil, resume: nil)
        return stream
    }

    @Test func testEachSessionsAgentIsGivenItsOwnToken() throws {
        let a = server.makeProcess(try #require(server.session("A")).info, resume: nil).approvalEnvironment
        let b = server.makeProcess(try #require(server.session("B")).info, resume: nil).approvalEnvironment
        #expect(a["VISOR_TOKEN"] == server.agentToken(for: "A"))
        #expect(b["VISOR_TOKEN"] == server.agentToken(for: "B"))
        #expect(a["VISOR_TOKEN"] != b["VISOR_TOKEN"])
        #expect(a["VISOR_TOKEN"] != server.sharedAgentToken)
    }

    @Test func testOneSessionsTokenCannotAskAsAnother() throws {
        let a = server.agentToken(for: "A")
        #expect(ask(from: "A", token: a).error == nil)
        #expect(ask(from: "B", token: a).error != nil, "A's token, asking as B")
        approval(for: "B", token: a)
        #expect(try #require(server.session("B")).info.pendingApproval == nil, "A's token, asking B's approval")
        approval(for: "A", token: a)
        #expect(try #require(server.session("A")).info.pendingApproval != nil)
    }

    @Test func testTheRESTSideTakesASessionsTokenNotTheSharedOne() {
        #expect(rest(server.agentToken(for: "A")) == 200)
        #expect(rest(server.sharedAgentToken) == 401, "no agent from an earlier build is left")
        #expect(rest("wrong") == 401)
    }

    @Test func testAnEndedSessionsTokenIsForgotten() {
        let a = server.agentToken(for: "A")
        var end = Envelope(type: "end")
        end.session = "A"
        server.handle(end, from: authenticatedClient())
        #expect(server.session("A") == nil)
        #expect(!server.isAgentToken(a))
        #expect(server.sessionAgentTokens["A"] == nil)
    }

    @Test func testTheSharedTokenIsRefusedWhereNoAgentFromBeforeRuns() {
        _ = server.agentToken(for: "A")
        #expect(ask(from: "A", token: server.sharedAgentToken).error != nil)
        #expect(!server.isAgentToken(server.sharedAgentToken))
    }

    @Test func testAnAgentFromBeforeKeepsTheSharedTokenUntilItEnds() async throws {
        let a = try #require(server.session("A"))
        let stream = await pickUp(a, ownToken: nil)
        #expect(server.holdsSharedToken(a))
        #expect(ask(from: "A", token: server.sharedAgentToken).error == nil, "the agent an earlier build started")
        #expect(ask(from: "B", token: server.sharedAgentToken).error != nil, "only as its own session")
        #expect(rest(server.sharedAgentToken) == 200)
        #expect(a.host?.ownToken == nil, "written down as holding the shared token, for the next launch")

        stream.agentEnds()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!server.holdsSharedToken(a))
        #expect(ask(from: "A", token: server.sharedAgentToken).error != nil, "its agent is gone")
        #expect(rest(server.sharedAgentToken) == 401)
    }

    @Test func testAnAgentGivenItsOwnTokenIsNotTakenWithTheShared() async throws {
        let a = try #require(server.session("A"))
        _ = server.agentToken(for: "A")
        _ = await pickUp(a, ownToken: true)
        #expect(!server.holdsSharedToken(a))
        #expect(ask(from: "A", token: server.sharedAgentToken).error != nil)
        #expect(ask(from: "A", token: server.agentToken(for: "A")).error == nil)
        #expect(a.host?.ownToken == true)
    }

    /// An agent under its host outlives the server that started it, and
    /// still holds the token it was given.
    @Test func testASessionsTokenOutlivesALaunch() {
        let a = server.agentToken(for: "A")
        let next = VisorServer(port: ServerTestCase.freePort())
        defer { next.stop() }
        #expect(next.agentToken(for: "A") == a)
        #expect(next.sharedAgentToken == server.sharedAgentToken)
    }

    @Test func testAKeptHostFromBeforeReadsAsHoldingTheSharedToken() throws {
        let old = Data(#"{"socket":"/tmp/vh.sock","line":4}"#.utf8)
        #expect(try JSONDecoder().decode(StoredHost.self, from: old).ownToken == nil)
    }

    private func authenticatedClient() -> ClientConnection {
        let client = ClientConnection(stream: FakeHostStream())
        client.authenticated = true
        return client
    }
}
}
