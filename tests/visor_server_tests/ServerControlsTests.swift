// The server's own settings over REST (`/api/settings`, VisorServer+Controls),
// as Visor.app's menu and Settings read and change them; the socket file as
// the app reaches it (its app key: let in whatever `sshEnabled` says, and
// listened on from the start, password or none); and the menu's own calls,
// the admin token reset without it and an emergency rotation, taken from
// the app alone.

import Foundation
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class ServerControlsTests {
    private var server: VisorServer!
    private var root: URL!
    private static let key = "the-app-key"

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-controls-tests-" + UUID().uuidString)
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

    private func rest(_ method: String, _ path: String, bearer: String? = "pw", body: String = "", socketFile: Bool = false,
                      appKey: String? = nil) -> HTTPResponse {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        if let appKey { headers[VisorServer.appKeyHeader] = appKey }
        return server.route(HTTPRequest(method: method, path: path, headers: headers, body: body, trusted: socketFile))
    }

    private func controls(_ response: HTTPResponse) -> ServerControls? {
        parseJSON(response.body).flatMap(ServerControls.init(json:))
    }

    @Test func theSettingsAreReadAsTheMenuShowsThem() throws {
        server.settings.lan = true
        let read = try #require(controls(rest("GET", "/api/settings")))
        #expect(read.password == "pw" && read.hasPassword)
        #expect(read.id == server.id && read.host == server.hostName && read.port == Int(server.port))
        #expect(read.settings.lan && !read.settings.vpn && read.settings.sshEnabled)
        #expect(read.settings.authentication == "password")
        #expect(!read.hasAdminToken)
        #expect(read.codes == server.connectionCodes)
        #expect(read.version == VisorServer.version)
        // Each REST route is an admin's: not without the password.
        #expect(rest("GET", "/api/settings", bearer: nil).status == 401)
        #expect(rest("PUT", "/api/settings", bearer: "wrong", body: #"{"lan":false}"#).status == 401)
    }

    @Test func aChangeSetsTheFieldsGivenAndLeavesTheRest() throws {
        let changed = rest("PUT", "/api/settings", body: ServerControlsChange(lan: true, proxyEnabled: true,
                                                                               publicAddress: "https://proxy.example/visor",
                                                                               clientsKeepMessages: false).json.encoded())
        #expect(changed.status == 200)
        let now = try #require(controls(changed))
        #expect(now.settings.lan && now.settings.proxyEnabled && !now.settings.clientsKeepMessages)
        #expect(now.settings.publicAddress == "https://proxy.example/visor")
        #expect(now.reachableAddress == "https://proxy.example/visor")
        #expect(!now.settings.vpn && now.settings.sshEnabled && now.settings.detachAgents, "the rest left")
        // Kept, for the next launch, as Settings kept them.
        let kept = ServerSettings.kept(at: VisorServer.settingsURL)
        #expect(kept.lan && kept.proxyEnabled && !kept.clientsKeepMessages)

        // The Sessions container's switch: kept in ServerSettings.container, the rest of it left.
        let container = try #require(controls(rest("PUT", "/api/settings", body: ServerControlsChange(containerEnabled: true).json.encoded())))
        #expect(container.settings.containerEnabled && container.settings.containerImageDigest.isEmpty)
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).container?.enabled == true)
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).container?.idleMinutes == 30)

        let password = rest("PUT", "/api/settings", body: ServerControlsChange(password: "  new-pw ").json.encoded())
        #expect(controls(password)?.password == "new-pw")
        #expect(server.password == "new-pw" && VisorServer.secrets.get("password") == "new-pw")
        #expect(rest("GET", "/api/settings", bearer: "new-pw").status == 200)
    }

    @Test func aChangeThatCanNotBeTakenChangesNothing() {
        let empty = rest("PUT", "/api/settings", body: ServerControlsChange(password: " ", lan: true).json.encoded())
        #expect(empty.status == 400)
        #expect(server.password == "pw" && !server.settings.lan)
        let auth = rest("PUT", "/api/settings", body: ServerControlsChange(authentication: "sso", vpn: true).json.encoded())
        #expect(auth.status == 400)
        #expect(server.settings.authentication == "password" && !server.settings.vpn)
        #expect(rest("PUT", "/api/settings", body: "not json").status == 400)
    }

    @Test func theSessionTableIsTheMenus() {
        let table = parseJSON(rest("GET", "/api/session-table").body)?["text"].string ?? ""
        #expect(table.hasPrefix("| Computer | Project |"))
        #expect(table == server.sessionTable())
    }

    /// With SSH clients let in, the socket file lets everyone on it in, as
    /// before; turned off, only the app with its key: anyone else there is
    /// taken as on the port.
    @Test func theAppIsLetInAtTheSocketFileWhatever() {
        server.appKey = Self.key
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true).status == 200, "SSH clients, while they're let in")
        server.settings.sshEnabled = false
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true).status == 401, "not without the key now")
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true, appKey: "guess").status == 401)
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true, appKey: Self.key).status == 200, "the app")
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: false, appKey: Self.key).status == 401, "never on the port")
        #expect(rest("GET", "/api/sessions", socketFile: true).status == 200, "the password, as on the port")

        // The channel's login the same.
        let app = ClientConnection(stream: SilentStream())
        app.trusted = server.trusts(socketFile: true, headers: [VisorServer.appKeyHeader: Self.key])
        server.handle(Envelope(type: "login"), from: app)
        #expect(app.authenticated)
        let other = ClientConnection(stream: SilentStream())
        other.trusted = server.trusts(socketFile: true, headers: [:])
        server.handle(Envelope(type: "login"), from: other)
        #expect(!other.authenticated)

        // A server with no app key (visor-server) has none to show.
        server.appKey = nil
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true, appKey: "").status == 401)
    }

    /// The menu's Reset Admin Token… without the current one, over REST:
    /// from the app alone, never the password or another on the socket.
    @Test func theAdminTokenIsResetByTheAppAlone() throws {
        server.appKey = Self.key
        let first = try #require(server.createAdminToken())
        #expect(rest("POST", "/api/admin-token/reset").status == 403, "not the password")
        #expect(rest("POST", "/api/admin-token/reset", bearer: first).status == 403, "nor the token itself")
        #expect(rest("POST", "/api/admin-token/reset", bearer: nil, socketFile: true).status == 403, "nor an SSH client")
        #expect(rest("POST", "/api/admin-token/reset", bearer: nil, appKey: Self.key).status == 401, "nor the key on the port")
        #expect(server.adminToken.admits(first))

        let reset = rest("POST", "/api/admin-token/reset", bearer: nil, socketFile: true, appKey: Self.key)
        #expect(reset.status == 200)
        let second = try #require(parseJSON(reset.body)?["token"].string)
        #expect(second != first && server.adminToken.admits(second) && !server.adminToken.admits(first))
        #expect(controls(rest("GET", "/api/settings"))?.hasAdminToken == true)
    }

    @Test func anEmergencyRotationIsTheAppsAlone() {
        server.appKey = Self.key
        #expect(rest("POST", "/api/keys/rotate", body: #"{"dropPrevious":true}"#).status == 403)
        #expect(rest("POST", "/api/keys/rotate", bearer: nil, body: #"{"dropPrevious":true}"#, socketFile: true).status == 403)
        let before = server.agentTokens.keys.kids
        let dropped = rest("POST", "/api/keys/rotate", bearer: nil, body: #"{"dropPrevious":true}"#, socketFile: true, appKey: Self.key)
        #expect(dropped.status == 200)
        #expect(server.agentTokens.keys.kids.count == 1 && !before.contains(server.agentTokens.keys.currentKID))
        // An ordinary rotation stays every admin's.
        #expect(rest("POST", "/api/keys/rotate").status == 200)
    }

    // MARK: The key asked again (AppKeyKeeper)

    /// The server agent's key, and the app's view of the same keychain.
    private func keepers(_ secrets: MemorySecrets) -> (server: AppKeyKeeper, app: AppKeyKeeper) {
        (AppKeyKeeper(secrets: { secrets }, log: { _ in }, attempts: 1, pause: {}),
         AppKeyKeeper(secrets: { secrets }, log: { _ in }, attempts: 1, pause: {}))
    }

    /// 0.65.1's agent: its key lost from the keychain as it was kept, so
    /// the app showed none and Reset Admin Token… was refused. Now the
    /// refusal has the server keep it again, and the app's next call shows
    /// it.
    @Test func theAppIsLetInAgainAfterA403OnceTheServerKeptItsKeyAgain() throws {
        let secrets = MemorySecrets()
        let (agent, app) = keepers(secrets)
        server.appKey = agent.serverKey()
        server.appKeyAskedAgain = { agent.reconciled($0) }
        let first = try #require(server.createAdminToken())
        secrets.set(AppKeyKeeper.name, nil)
        #expect(app.shown == nil)

        #expect(rest("POST", "/api/admin-token/reset", bearer: nil, socketFile: true, appKey: app.shown).status == 403)
        #expect(app.shown == server.appKey, "kept again as it refused")
        let reset = rest("POST", "/api/admin-token/reset", bearer: nil, socketFile: true, appKey: app.shown)
        #expect(reset.status == 200)
        #expect(!server.adminToken.admits(first))
        let dropped = rest("POST", "/api/keys/rotate", bearer: nil, body: #"{"dropPrevious":true}"#, socketFile: true, appKey: app.shown)
        #expect(dropped.status == 200, "the emergency rotation too")
    }

    /// Another process of Visor's kept a new key since this server started
    /// (the app's own server before the agent, say): the server takes it.
    @Test func aKeyKeptSinceIsTakenByTheServer() {
        let secrets = MemorySecrets()
        let (agent, app) = keepers(secrets)
        server.appKey = agent.serverKey()
        server.appKeyAskedAgain = { agent.reconciled($0) }
        secrets.set(AppKeyKeeper.name, "made-since")
        server.settings.sshEnabled = false
        #expect(rest("GET", "/api/sessions", bearer: nil, socketFile: true, appKey: app.shown).status == 200)
        #expect(server.appKey == "made-since")
    }

    /// With SSH clients off, every call of the app's wants its key: one
    /// lost locked the app out of its own server (401). Asked again, at most
    /// every few seconds, and never for a call on the port.
    @Test func withSSHClientsOffTheAppIsLockedOutNoLonger() {
        let secrets = MemorySecrets()
        let (agent, app) = keepers(secrets)
        server.appKey = agent.serverKey()
        server.appKeyAskedAgain = { agent.reconciled($0) }
        server.settings.sshEnabled = false
        secrets.set(AppKeyKeeper.name, nil)
        #expect(rest("GET", "/api/settings", bearer: nil, socketFile: false, appKey: app.shown).status == 401)
        #expect(app.shown == nil, "not asked again for a call on the port")
        #expect(rest("GET", "/api/settings", bearer: nil, socketFile: true, appKey: app.shown).status == 401)
        #expect(rest("GET", "/api/settings", bearer: nil, socketFile: true, appKey: app.shown).status == 200)
        // Lost again at once: not asked again until a few seconds on.
        secrets.set(AppKeyKeeper.name, nil)
        #expect(rest("GET", "/api/settings", bearer: nil, socketFile: true, appKey: "guess").status == 401)
        #expect(app.shown == nil)
        server.appKeyLastAsked = Date().addingTimeInterval(-VisorServer.appKeyAskInterval)
        #expect(rest("GET", "/api/settings", bearer: nil, socketFile: true, appKey: "guess").status == 401)
        #expect(app.shown == server.appKey)
    }

    /// The app's own server listens on its socket file from its start,
    /// before there is a password, so the app can set one; the port waits
    /// for it.
    @Test func theAppsServerServesItsSocketFileWithoutAPassword() async throws {
        let path = "/tmp/visor-controls-\(ProcessInfo.processInfo.processIdentifier).sock"
        VisorServer.socketPathOverride = path
        defer { VisorServer.socketPathOverride = nil }
        let bare = VisorServer(port: ServerTestCase.freePort())
        defer { bare.stop() }
        bare.appKey = Self.key
        bare.settings.sshEnabled = false
        bare.password = ""
        bare.start()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!bare.listening, "no port without a password")
        #expect(bare.socketListener != nil)
    }
}
}

/// A stream that takes what is sent to it and says nothing.
@MainActor
private final class SilentStream: ByteStream {
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { sent?() }
    func close() {}
}
