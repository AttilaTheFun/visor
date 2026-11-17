// The admin token: an opaque random secret whose SHA-256 alone is held, an
// additional REST credential beside the password and the trusted socket.
// Kept (the menu bar app's): made only when there is none, rotated only by
// presenting it (the old one refused at once), reset without it only from
// the menu. Given at launch (the command-line server's): its hash in
// memory alone, never written, never on the command line; none given,
// none. And the signing keys rotated over REST, an emergency rotation
// there only where the server allows it. `visor-server admin-token` and
// `keys rotate` reach the running server over its trusted socket.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
@testable import VisorServerCLI
import VisorServerLinux
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class AdminTokenTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-admin-token-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func rest(_ method: String, _ path: String, bearer: String? = "pw", body: String = "", trusted: Bool = false) -> HTTPResponse {
        server.route(HTTPRequest(method: method, path: path, headers: bearer.map { ["authorization": "Bearer " + $0] } ?? [:], body: body,
                                 trusted: trusted))
    }

    private func token(_ response: HTTPResponse) -> String? {
        parseJSON(response.body)?["token"].string
    }

    /// Every file under `folder`, as text.
    private func everythingWritten(under folder: URL) -> String {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// `GET /api/hello` hands out a socket-login token that never expires:
    /// those handed out to the admin token (or to one of them) go when it
    /// is rotated or reset, the password's stay.
    @Test func helloTokensTheAdminTokenLedToGoWhenItIsReplaced() throws {
        let first = try #require(token(rest("POST", "/api/admin-token")))
        let byAdmin = try #require(token(rest("GET", "/api/hello", bearer: first)))
        let byThat = try #require(token(rest("GET", "/api/hello", bearer: byAdmin)), "a hello token's own hello")
        let byPassword = try #require(token(rest("GET", "/api/hello")))
        for bearer in [byAdmin, byThat, byPassword] { #expect(rest("GET", "/api/sessions", bearer: bearer).status == 200) }

        let rotated = rest("POST", "/api/admin-token/rotate", bearer: first)
        #expect(rotated.status == 200)
        #expect(rest("GET", "/api/sessions", bearer: byAdmin).status == 401, "the admin token's hello token is gone")
        #expect(rest("GET", "/api/sessions", bearer: byThat).status == 401, "and the one it led to")
        #expect(rest("GET", "/api/sessions", bearer: byPassword).status == 200, "the password's stays")

        let second = try #require(token(rotated))
        let bySecond = try #require(token(rest("GET", "/api/hello", bearer: second)))
        #expect(server.resetAdminToken() != nil)
        #expect(rest("GET", "/api/sessions", bearer: bySecond).status == 401, "gone with a reset too")
        #expect(rest("GET", "/api/sessions", bearer: byPassword).status == 200)
    }

    @Test func aKeptAdminTokenIsMadeOnlyWhenThereIsNone() throws {
        #expect(parseJSON(rest("GET", "/api/admin-token").body)?["exists"].bool == false)
        #expect(parseJSON(rest("GET", "/api/admin-token").body)?["holding"].string == "kept")
        let made = rest("POST", "/api/admin-token")
        #expect(made.status == 201)
        let first = try #require(token(made))
        #expect(first.count == 64 && first.allSatisfy(\.isHexDigit), "32 random bytes")
        // Only its hash is kept.
        let kept = try #require(VisorServer.secrets.get(AdminToken.secretKey))
        #expect(kept == AdminToken.hex(AdminToken.digest(first)) && kept != first)
        #expect(!everythingWritten(under: root).contains(first))

        let again = rest("POST", "/api/admin-token")
        #expect(again.status == 409, "never a second while there is one")
        #expect(token(again) == nil)
        #expect(server.createAdminToken() == nil)
        #expect(parseJSON(rest("GET", "/api/admin-token").body)?["exists"].bool == true)
        // It is a REST credential; a guess isn't.
        #expect(rest("GET", "/api/sessions", bearer: first).status == 200)
        #expect(rest("GET", "/api/sessions", bearer: String(first.dropLast()) + "0").status == 401)
        // Kept across a launch, as its hash.
        let next = VisorServer(port: ServerTestCase.freePort())
        defer { next.stop() }
        #expect(next.adminToken.admits(first))
    }

    @Test func rotatingTakesTheCurrentTokenAndTheOldStopsAtOnce() throws {
        let first = try #require(server.createAdminToken())
        #expect(rest("POST", "/api/admin-token/rotate").status == 403, "the password doesn't rotate it")
        #expect(rest("POST", "/api/admin-token/rotate", bearer: nil, trusted: true).status == 403, "nor the trusted socket")
        #expect(rest("POST", "/api/admin-token/rotate", bearer: "guess").status == 401)
        #expect(server.adminToken.admits(first), "still the one")

        let rotated = rest("POST", "/api/admin-token/rotate", bearer: first)
        #expect(rotated.status == 200)
        let second = try #require(token(rotated))
        #expect(second != first)
        #expect(rest("GET", "/api/sessions", bearer: first).status == 401, "the old one refused at once")
        #expect(rest("GET", "/api/sessions", bearer: second).status == 200)
        #expect(rest("POST", "/api/admin-token/rotate", bearer: first).status == 401)
    }

    @Test func theMenuResetsItWithoutTheCurrentOne() throws {
        let first = try #require(server.createAdminToken())
        let reset = try #require(server.resetAdminToken())
        #expect(reset != first)
        #expect(!server.adminToken.admits(first) && server.adminToken.admits(reset))
    }

    @Test func aTokenGivenAtLaunchIsHeldAsItsHashAloneAndNeverWritten() throws {
        let given = AdminToken.generate()
        server.useAdminTokenGivenAtLaunch(given)
        #expect(server.hasAdminToken && server.adminToken.holding == .givenAtLaunch)
        #expect(rest("GET", "/api/sessions", bearer: given).status == 200)
        #expect(VisorServer.secrets.get(AdminToken.secretKey) == nil, "not with the secrets")
        server.saveArchiveNow()
        #expect(!everythingWritten(under: root).contains(given), "nor in any file")
        #expect(parseJSON(rest("GET", "/api/admin-token").body)?["holding"].string == "givenAtLaunch")
        // Made, rotated and reset only by relaunching.
        #expect(rest("POST", "/api/admin-token").status == 409)
        #expect(rest("POST", "/api/admin-token/rotate", bearer: given).status == 409)
        #expect(server.resetAdminToken() == nil)
        #expect(server.adminToken.admits(given))
    }

    @Test func noTokenGivenAtLaunchIsNoAdminToken() {
        server.useAdminTokenGivenAtLaunch(nil)
        #expect(!server.hasAdminToken)
        #expect(rest("GET", "/api/sessions").status == 200, "the password still")
        #expect(rest("GET", "/api/sessions", bearer: nil, trusted: true).status == 200, "and the trusted socket")
        #expect(rest("GET", "/api/sessions", bearer: "anything").status == 401)
        #expect(rest("GET", "/api/sessions", bearer: "").status == 401)
    }

    @Test func theAdminTokenIsGivenAtLaunchNeverOnTheCommandLine() throws {
        #expect(throws: CommandLineError.self) { try ServerOptions(["--admin-token", "secret"]) }
        #expect(try ServerOptions([], environment: ["VISOR_ADMIN_TOKEN": "from-env"]).adminToken == "from-env")
        let file = root.appendingPathComponent("admin-token")
        try Data("from-file\n".utf8).write(to: file)
        let options = try ServerOptions(["--admin-token-file", file.path], environment: ["VISOR_ADMIN_TOKEN": "from-env"])
        #expect(options.adminToken == "from-file", "the argument wins")
        #expect(options.arguments.contains(file.path) && !options.arguments.contains("from-file"), "passed on by its path alone")
        let fromEnvironment = try ServerOptions([], environment: ["VISOR_ADMIN_TOKEN": "from-env"])
        #expect(!fromEnvironment.arguments.joined(separator: " ").contains("from-env"), "the environment's stays there")
        #expect(fromEnvironment.backgroundProblem == nil)
    }

    @Test func theSigningKeysAreRotatedOverRESTAndInAnEmergencyOnlyWhereAllowed() throws {
        let before = server.agentTokens.keys.currentKID
        let token = server.agentTokens.mint(.session, session: "S")
        let listed = rest("GET", "/api/keys")
        #expect(parseJSON(listed.body)?["current"].string == before)
        let kept = try #require(VisorServer.secrets.get(SigningKeys.secretKey))
        let keys = try #require(parseJSON(kept)?["keys"][before]["key"].string)
        #expect(!listed.body.contains(keys), "names, never keys")

        #expect(rest("POST", "/api/keys/rotate", body: "{}").status == 200)
        #expect(server.agentTokens.keys.currentKID != before)
        #expect(server.agentTokens.verify(token, as: .session).isSuccess, "the one before kept")
        // The menu bar app's: an emergency rotation is its menu's alone.
        #expect(rest("POST", "/api/keys/rotate", body: #"{"dropPrevious":true}"#).status == 403)
        #expect(server.agentTokens.keys.kids.count == 2)
        // The command-line server's (given its admin token at launch).
        server.useAdminTokenGivenAtLaunch(nil)
        #expect(rest("POST", "/api/keys/rotate", body: #"{"dropPrevious":true}"#).status == 200)
        #expect(server.agentTokens.keys.kids == [server.agentTokens.keys.currentKID])
        #expect(server.agentTokens.verify(token, as: .session) == .failure(.unknownKey))
        #expect(!server.hasAdminToken, "the admin token untouched")
    }

    /// `visor-server admin-token` and `keys rotate`, over the running
    /// server's trusted socket.
    @Test func theCommandLineReachesTheRunningServerOverItsSocket() async throws {
        server.start()
        let path = "/tmp/visor-admin-\(UUID().uuidString.prefix(8)).sock"
        let listener = try ServerPlatform.current.listening.listen(ListeningOptions(port: 0, unixPath: path)) { [weak server] stream in
            server?.accept(stream, trusted: true)
        }
        defer {
            listener.stop()
            try? FileManager.default.removeItem(atPath: path)
        }
        let system = LinuxSystem()
        let made = try await LocalServerCall(method: "POST", path: "/api/admin-token").send(through: system, socket: path)
        #expect(made.status == 201, Comment(rawValue: made.body))
        let first = try ServerCommand.token(in: made)
        #expect(server.adminToken.admits(first))
        let again = try await LocalServerCall(method: "POST", path: "/api/admin-token").send(through: system, socket: path)
        #expect(again.status == 409)
        #expect(ServerCommand.why(again) == AdminToken.Refusal.exists.message, "the CLI says why")

        let unshown = try await LocalServerCall(method: "POST", path: "/api/admin-token/rotate").send(through: system, socket: path)
        #expect(unshown.status == 403, "the socket doesn't rotate it without the current one")
        let rotated = try await LocalServerCall(method: "POST", path: "/api/admin-token/rotate", bearer: first).send(through: system, socket: path)
        let second = try ServerCommand.token(in: rotated)
        #expect(second != first && server.adminToken.admits(second) && !server.adminToken.admits(first))

        let kid = server.agentTokens.keys.currentKID
        let keys = try await LocalServerCall(method: "POST", path: "/api/keys/rotate", body: "{}").send(through: system, socket: path)
        #expect(keys.status == 200 && server.agentTokens.keys.currentKID != kid)

        await #expect(throws: CommandLineError.self) {
            _ = try await LocalServerCall(method: "GET", path: "/api/keys").send(through: system, socket: path + ".none")
        }
    }

    @Test func agentsAreNeverGivenTheAdminToken() {
        let environment = ["VISOR_ADMIN_TOKEN": "admin", "SHIREWORKS_SESSION": "lease", "PATH": "/usr/bin", "VISOR_SESSION": "A"]
        #expect(AgentEnvironment.forNativeAgent(environment) == ["SHIREWORKS_SESSION": "lease", "PATH": "/usr/bin", "VISOR_SESSION": "A"])
        #expect(AgentEnvironment.forRunnerAgent(environment) == ["PATH": "/usr/bin", "VISOR_SESSION": "A"])
        setenv("VISOR_ADMIN_TOKEN", "admin-of-the-server", 1)
        defer { unsetenv("VISOR_ADMIN_TOKEN") }
        #expect(ToolPath.environment()["VISOR_ADMIN_TOKEN"] == nil, "nor what Visor runs for its native agents")
        server.sessions = [SessionRecord(info: SessionInfo(id: "N", agent: .claude, cwd: "/tmp", title: "N", created: 0),
                                         process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])]
        let given = server.makeProcess(server.sessions[0].info, resume: nil).approvalEnvironment
        #expect(given["VISOR_ADMIN_TOKEN"] == nil)
    }
}
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
