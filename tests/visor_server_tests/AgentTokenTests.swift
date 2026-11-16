// Each native session's agent holds a JWT for its own session (`sub`),
// minted with the server's signing keys and kept in a token file it reads
// (VISOR_TOKEN_FILE, 600, re-minted hourly): one session's can't ask, or
// answer an approval, or reach the passed-on MCP servers, as another's; a
// wrong, expired or archived session's token is refused; no agent's token
// is ever a REST credential. Agents started before this build keep their
// older token (the shared one, or their session's random one) until they
// are gone, and only as their own session.

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
        // Never the real keychain. A build before 0.60 kept the shared token.
        VisorServer.secrets = MemorySecrets()
        VisorServer.secrets.set("agentToken", "shared-token-of-0.59")
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

    private func ask(from caller: String, token: String, mode: String = "sessions") -> Envelope {
        var e = Envelope(type: "agent")
        e.token = token
        e.client = caller
        e.mode = mode
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

    private func rest(_ bearer: String?, _ method: String = "GET", _ path: String = "/api/sessions", body: String = "") -> Int {
        let headers = bearer.map { ["authorization": "Bearer " + $0] } ?? [:]
        return server.route(HTTPRequest(method: method, path: path, headers: headers, body: body)).status
    }

    private func claims(_ token: String) throws -> AgentTokenClaims {
        try server.agentTokens.verify(token, as: .session).get()
    }

    /// The agent of `record`, left under its host by an earlier launch,
    /// picked up as this launch does.
    private func pickUp(_ record: SessionRecord, ownToken: Bool?, jwt: Bool?) async -> FakeHostStream {
        let stream = FakeHostStream()
        ServerPlatform.current.agentHosts = FakeHosting(stream: stream)
        await server.pickUp(record, host: StoredHost(socket: "/tmp/vh-test.sock", line: 0, carried: nil, ownToken: ownToken, jwt: jwt),
                            agentPID: nil, resume: nil)
        return stream
    }

    private func permissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test func eachSessionsAgentIsGivenAJWTForItsOwnSession() throws {
        let a = server.makeProcess(try #require(server.session("A")).info, resume: nil).approvalEnvironment
        let b = server.makeProcess(try #require(server.session("B")).info, resume: nil).approvalEnvironment
        let token = try #require(a["VISOR_TOKEN"])
        #expect(JWT.isShaped(token))
        let parts = try #require(JWT.parts(of: token))
        #expect(parts.header.alg == "HS256" && parts.header.typ == "JWT" && parts.header.kid == server.agentTokens.keys.currentKID)
        let said = try claims(token)
        #expect(said.iss == server.id && said.aud == "visor.session" && said.sub == "A" && said.agent == nil)
        #expect(said.scope == ["messages", "approvals", "mcp"])
        #expect(said.exp - said.iat == 24 * 3600, "a day")
        #expect(!said.jti.isEmpty)
        #expect(try claims(try #require(b["VISOR_TOKEN"])).sub == "B")
        #expect(a["VISOR_TOKEN"] != b["VISOR_TOKEN"])

        // Its file: where it is told, this user's alone, its own session's.
        let file = try #require(a["VISOR_TOKEN_FILE"])
        #expect(file == VisorServer.sessionTokenFile(of: "A").path)
        #expect(permissions(file) == 0o600)
        #expect(permissions((file as NSString).deletingLastPathComponent) == 0o700)
        let written = try String(contentsOfFile: file, encoding: .utf8)
        #expect(try claims(written).sub == "A")
        #expect(VisorServer.secrets.get(VisorServer.sessionAgentTokensKey) == nil, "no table of them kept")
    }

    @Test func aSessionsTokenActsOnlyAsItsOwnSession() throws {
        let a = server.agentToken(for: "A")
        #expect(ask(from: "A", token: a).error == nil)
        #expect(ask(from: "B", token: a).error != nil, "A's token, asking as B")
        #expect(server.agentSession("B", presenting: a, for: .mcp) == nil, "nor B's passed-on MCP servers")
        #expect(server.agentSession("A", presenting: a, for: .mcp) != nil)
        approval(for: "B", token: a)
        #expect(try #require(server.session("B")).info.pendingApproval == nil, "A's token, asking B's approval")
        approval(for: "A", token: a)
        #expect(try #require(server.session("A")).info.pendingApproval != nil)
    }

    @Test func aWrongTokenIsRefused() throws {
        let a = server.agentToken(for: "A")
        let pieces = a.split(separator: ".").map(String.init)
        // Its payload changed to B's, its signature kept: a forgery.
        var forged = try #require(JSONSerialization.jsonObject(with: try #require(JWT.data(base64URL: pieces[1]))) as? [String: Any])
        forged["sub"] = "B"
        let forgedPayload = JWT.base64URL(try JSONSerialization.data(withJSONObject: forged))
        let wrong = [
            pieces[0] + "." + forgedPayload + "." + pieces[2],
            pieces[0] + "." + pieces[1] + "." + String(pieces[2].dropLast(2)),
            String(a.dropLast()), a + "x", "", "random-not-a-jwt",
            // Signed with a key of another server's, under this one's kid.
            try JWT.sign(try claims(a), key: Data(repeating: 7, count: 32), kid: server.agentTokens.keys.currentKID),
            // A kid this server never had.
            try JWT.sign(try claims(a), key: Data(repeating: 7, count: 32), kid: "0000000000000000"),
        ]
        for token in wrong {
            #expect(server.agentSession("A", presenting: token, for: .messages) == nil, Comment(rawValue: token))
            #expect(server.agentSession("B", presenting: token, for: .messages) == nil, Comment(rawValue: token))
        }
        #expect(server.agentTokens.verify(wrong[0], as: .session) == .failure(.badSignature))
        #expect(server.agentTokens.verify(wrong[7], as: .session) == .failure(.unknownKey))
        // Another issuer, with the same keys: refused.
        let elsewhere = AgentTokens(secrets: VisorServer.secrets, issuer: "another-server")
        #expect(server.agentSession("A", presenting: elsewhere.mint(.session, session: "A"), for: .messages) == nil)
        #expect(server.agentTokens.verify(elsewhere.mint(.session, session: "A"), as: .session) == .failure(.wrongIssuer))
        // A runner's agent's token for the same session: another audience.
        let runner = server.agentTokens.mint(.runnerAgent, session: "A", agent: "agent-1")
        #expect(server.agentSession("A", presenting: runner, for: .messages) == nil)
        #expect(server.agentTokens.verify(runner, as: .session) == .failure(.wrongAudience))
        // Expired.
        let old = server.agentTokens.mint(.session, session: "A", now: Date().addingTimeInterval(-25 * 3600))
        #expect(server.agentSession("A", presenting: old, for: .messages) == nil)
        #expect(server.agentTokens.verify(old, as: .session) == .failure(.expired))
        // Its scope, as minted, has no `job`.
        #expect(server.agentTokens.verify(a, as: .session, scope: .job) == .failure(.outOfScope))
    }

    @Test func anArchivedOrEndedSessionsTokenIsRefused() throws {
        let a = server.agentToken(for: "A")
        try #require(server.session("A")).info.archived = true
        #expect(server.agentSession("A", presenting: a, for: .messages) == nil)
        #expect(ask(from: "A", token: a).error != nil)
        approval(for: "A", token: a)
        #expect(try #require(server.session("A")).info.pendingApproval == nil)

        let b = server.agentToken(for: "B")
        var end = Envelope(type: "end")
        end.session = "B"
        server.handle(end, from: authenticatedClient())
        #expect(server.session("B") == nil)
        #expect(server.agentSession("B", presenting: b, for: .messages) == nil)
        #expect(!FileManager.default.fileExists(atPath: VisorServer.sessionTokenFile(of: "B").path), "its token file gone")
    }

    /// Every REST route is an admin's: no agent's token is let in to any,
    /// a session's or a runner's agent's, live or expired, even where the
    /// server asks nothing.
    @Test func noAgentsTokenIsARESTCredential() throws {
        let routes: [(String, String, String)] = [
            ("GET", "/api/hello", ""), ("GET", "/api/search?q=x", ""), ("GET", "/api/sessions", ""), ("GET", "/api/folders", ""),
            ("POST", "/api/folders", #"{"path":"/tmp/x"}"#), ("GET", "/api/resumable?agent=claude", ""), ("GET", "/api/file?path=/tmp/x", ""),
            ("POST", "/api/file", "{}"), ("POST", "/api/relocate", "{}"), ("GET", "/api/code", ""), ("GET", "/api/codes", ""),
            ("GET", "/api/versions", ""), ("POST", "/api/relay", "{}"), ("POST", "/api/relay/deliver", "{}"),
            ("POST", "/api/relay/receipt", "{}"), ("POST", "/api/push/key", "{}"), ("POST", "/api/push/test", "{}"),
            ("POST", "/api/push", "{}"), ("POST", "/api/ssh/keys", "{}"), ("POST", "/api/restart", "{}"), ("GET", "/api/push-proxy", ""),
            ("PUT", "/api/push-proxy", #"{"url":""}"#), ("GET", "/api/mcp", ""), ("PUT", "/api/mcp", #"{"endpoints":[]}"#),
            ("POST", "/api/quit", ""), ("POST", "/api/sessions", "{}"), ("POST", "/api/jobs", "{}"), ("GET", "/api/runners/tokens", ""),
            ("POST", "/api/runners/tokens", #"{"runner":"r"}"#), ("DELETE", "/api/runners/tokens/r", ""), ("GET", "/api/admin-token", ""),
            ("POST", "/api/admin-token", ""), ("POST", "/api/admin-token/rotate", ""), ("GET", "/api/keys", ""),
            ("POST", "/api/keys/rotate", "{}"), ("DELETE", "/api/sessions/B", ""), ("POST", "/api/sessions/B/archive", "{}"),
            ("GET", "/api/sessions/B/state", ""), ("GET", "/api/sessions/B/commands", ""), ("GET", "/api/sessions/B/mail", ""),
            ("GET", "/api/backups", ""), ("POST", "/api/backups", "{}"), ("GET", "/api/account?agent=claude", ""),
        ]
        let keysBefore = server.agentTokens.keys.kids
        let agentTokens = [server.agentToken(for: "A"), server.agentToken(for: "B"),
                           server.agentTokens.mint(.runnerAgent, session: "A", agent: "agent-1"),
                           server.agentTokens.mint(.session, session: "A", now: Date().addingTimeInterval(-25 * 3600))]
        for asksNothing in [false, true] {
            server.settings.authentication = asksNothing ? "none" : "password"
            for (method, path, body) in routes {
                for token in agentTokens {
                    #expect(rest(token, method, path, body: body) == 401, "\(method) \(path)")
                }
            }
        }
        server.settings.authentication = "password"
        #expect(server.sessions.count == 2 && server.agentTokens.keys.kids == keysBefore && !server.hasAdminToken, "nothing done")
        let refused = server.route(HTTPRequest(method: "GET", path: "/api/sessions",
                                               headers: ["authorization": "Bearer " + agentTokens[0]], body: ""))
        #expect(refused.body.contains("never over REST"), Comment(rawValue: refused.body))
        #expect(rest("pw") == 200, "the password is")
    }

    @Test func theTokenFileIsReMintedAndGoesWithItsSession() async throws {
        let record = try #require(server.session("A"))
        let file = VisorServer.sessionTokenFile(of: "A").path
        let first = server.writeSessionToken(of: "A")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == first)
        try await Task.sleep(for: .milliseconds(1100))
        server.refreshSessionTokenFiles()
        let second = try String(contentsOfFile: file, encoding: .utf8)
        #expect(second != first, "re-minted")
        #expect(try claims(second).sub == "A" && claims(second).iat > claims(first).iat)
        #expect(permissions(file) == 0o600)
        #expect(server.agentSession("A", presenting: first, for: .messages) != nil, "the one before still good until it ends")

        server.archive(record)
        #expect(!FileManager.default.fileExists(atPath: file), "archived: gone")
        server.refreshSessionTokenFiles()
        #expect(!FileManager.default.fileExists(atPath: file), "and not re-minted")
        server.unarchive(record)
        #expect(try claims(try String(contentsOfFile: file, encoding: .utf8)).sub == "A", "unarchived: back")
    }

    @Test func rotatingTheKeysReMintsTheTokenFilesAndAnEmergencyRefusesTheOld() throws {
        let file = VisorServer.sessionTokenFile(of: "A").path
        let before = server.writeSessionToken(of: "A")
        let oldKID = server.agentTokens.keys.currentKID
        server.rotateSigningKeys(dropPrevious: false)
        let newKID = server.agentTokens.keys.currentKID
        #expect(newKID != oldKID && server.agentTokens.keys.kids.sorted() == [oldKID, newKID].sorted())
        let rotated = try String(contentsOfFile: file, encoding: .utf8)
        #expect(JWT.parts(of: rotated)?.header.kid == newKID, "the file's re-minted with the new key")
        #expect(server.agentSession("A", presenting: before, for: .messages) != nil, "the old key's tokens still good")

        server.rotateSigningKeys(dropPrevious: true)
        #expect(server.agentTokens.keys.kids == [server.agentTokens.keys.currentKID], "every other key dropped")
        #expect(server.agentSession("A", presenting: before, for: .messages) == nil)
        #expect(server.agentSession("A", presenting: rotated, for: .messages) == nil)
        let fresh = try String(contentsOfFile: file, encoding: .utf8)
        #expect(server.agentSession("A", presenting: fresh, for: .messages) != nil, "its agent carries on with the file's")
    }

    @Test func theKeysAreKeptAcrossALaunch() {
        let a = server.agentToken(for: "A")
        let next = VisorServer(port: ServerTestCase.freePort())
        defer { next.stop() }
        next.sessions = [record("A", "One")]
        #expect(next.agentSession("A", presenting: a, for: .messages) != nil, "an agent under its host outlives the server")
    }

    /// 0.60 and 0.61 gave each session a random token: an agent of theirs
    /// left under its host keeps it, as its own session alone, until it is
    /// gone.
    @Test func anOldRandomTokenIsTakenOnlyFromItsOwnAgentFromBefore() async throws {
        server.sessionAgentTokens = ["A": "random-a", "B": "random-b"]
        let a = try #require(server.session("A"))
        #expect(ask(from: "A", token: "random-a").error != nil, "no agent from before holds it")
        let stream = await pickUp(a, ownToken: true, jwt: nil)
        #expect(server.holdsRandomToken(a))
        #expect(ask(from: "A", token: "random-a").error == nil, "the agent 0.61 started")
        #expect(ask(from: "B", token: "random-a").error != nil, "only as its own session")
        #expect(ask(from: "A", token: "random-b").error != nil, "never another session's")
        #expect(ask(from: "B", token: "random-b").error != nil, "B's agent is no agent from before")
        #expect(rest("random-a") == 401, "never a REST credential")
        #expect(a.host?.jwt == nil && a.host?.ownToken == true, "written down as holding its random token, for the next launch")

        stream.agentEnds()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!server.holdsRandomToken(a))
        #expect(ask(from: "A", token: "random-a").error != nil, "its agent is gone")
    }

    @Test func anAgentStartedWithAJWTIsNotTakenWithAnOlderToken() async throws {
        server.sessionAgentTokens = ["A": "random-a"]
        let a = try #require(server.session("A"))
        _ = await pickUp(a, ownToken: true, jwt: true)
        #expect(!server.holdsRandomToken(a) && !server.holdsSharedToken(a))
        #expect(ask(from: "A", token: "random-a").error != nil)
        #expect(ask(from: "A", token: "shared-token-of-0.59").error != nil)
        #expect(ask(from: "A", token: server.agentToken(for: "A")).error == nil)
        #expect(a.host?.jwt == true)
    }

    @Test func anAgentFromBefore0_60KeepsTheSharedTokenUntilItEnds() async throws {
        let a = try #require(server.session("A"))
        #expect(ask(from: "A", token: "shared-token-of-0.59").error != nil, "no agent from before 0.60 holds it")
        let stream = await pickUp(a, ownToken: nil, jwt: nil)
        #expect(server.holdsSharedToken(a))
        #expect(ask(from: "A", token: "shared-token-of-0.59").error == nil)
        #expect(ask(from: "B", token: "shared-token-of-0.59").error != nil, "only as its own session")
        #expect(rest("shared-token-of-0.59") == 401, "never a REST credential")
        #expect(a.host?.ownToken == nil)
        stream.agentEnds()
        try await Task.sleep(for: .milliseconds(50))
        #expect(ask(from: "A", token: "shared-token-of-0.59").error != nil, "its agent is gone")
    }

    @Test func aKeptHostFromBeforeReadsAsHoldingAnOlderToken() throws {
        let shared = Data(#"{"socket":"/tmp/vh.sock","line":4}"#.utf8)
        #expect(try JSONDecoder().decode(StoredHost.self, from: shared).ownToken == nil)
        let random = Data(#"{"socket":"/tmp/vh.sock","line":4,"ownToken":true}"#.utf8)
        let host = try JSONDecoder().decode(StoredHost.self, from: random)
        #expect(host.ownToken == true && host.jwt == nil)
    }

    private func authenticatedClient() -> ClientConnection {
        let client = ClientConnection(stream: FakeHostStream())
        client.authenticated = true
        return client
    }
}
}
