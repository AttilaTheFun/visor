// A server reached at its socket file as Visor.app reaches its own
// (libraries/visor_socket_file): the REST side and the live channel over a
// real connection to a real server's socket file, `http+unix://` and
// `ws+unix://`, with no password; with SSH clients turned off, the app's key
// alone lets it in; and the host's services wrapped to send those URLs there
// and every other as before.

import Foundation
import VisorProtocol
@testable import VisorServer
import VisorServerPOSIX
import VisorServices
import VisorSocketFile
import VisorSystem
import Synchronization
import Testing

extension ServerTests {
@Suite @MainActor final class SocketFileClientTests {
    private var server: VisorServer!
    private var root: URL!
    private let path = "/tmp/visor-socket-file-\(ProcessInfo.processInfo.processIdentifier).sock"
    private static let key = "socket-file-tests-key"

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-socket-file-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = path
        server = VisorServer(port: ServerTestCase.freePort())
        server.appKey = Self.key
        server.password = "pw"
        try await waitForTheSocketFile()
    }

    isolated deinit {
        server.stop()
        VisorServer.socketPathOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForTheSocketFile() async throws {
        for _ in 0..<100 where !POSIXUnixSocket.answers(path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(POSIXUnixSocket.answers(path), "the socket file is served")
    }

    private var address: String { SocketFileURL.address(socket: path) }

    private func http(showingKey: Bool = true) -> SocketFileHTTPService {
        let key = showingKey ? Self.key : nil
        return SocketFileHTTPService(connect: { await POSIXUnixSocket.connect($0) },
                                     headers: { key.map { [VisorServer.appKeyHeader: $0] } ?? [:] })
    }

    private func channel(showingKey: Bool = true) -> SocketFileSocketService {
        let key = showingKey ? Self.key : nil
        return SocketFileSocketService(connect: { await POSIXUnixSocket.connect($0) },
                                       headers: { key.map { [VisorServer.appKeyHeader: $0] } ?? [:] })
    }

    @Test func theRESTSideAnswersAtTheSocketFileWithNoPassword() async throws {
        let hello = Envelope.decode(try await http().request(method: "GET", url: address + "/api/hello", body: "", headers: [:]))
        #expect(hello?.type == "hello" && hello?.id == server.id)
        let settings = try await http().request(method: "GET", url: address + "/api/settings", body: "", headers: [:])
        let controls = try #require(parseJSON(settings).flatMap(ServerControls.init(json:)))
        #expect(controls.password == "pw" && controls.listening)
        let changed = try await http().request(method: "PUT", url: address + "/api/settings", body: ServerControlsChange(vpn: true).json.encoded(),
                                               headers: [:])
        #expect(parseJSON(changed).flatMap(ServerControls.init(json:))?.settings.vpn == true)
        #expect(server.settings.vpn)
        // A refusal's status and body, as a client reads them.
        do {
            _ = try await http().request(method: "POST", url: address + "/api/admin-token/rotate", body: "", headers: [:])
            Issue.record("rotating without the current token was taken")
        } catch {
            #expect(http().status(of: error) == 403)
            #expect(Envelope.decode(http().body(of: error) ?? "", defaultType: "reply")?.message?.isEmpty == false)
        }
    }

    @Test func withSSHClientsOffTheAppsKeyAloneLetsItIn() async throws {
        server.settings.sshEnabled = false
        try await waitForTheSocketFile()
        do {
            _ = try await http(showingKey: false).request(method: "GET", url: address + "/api/sessions", body: "", headers: [:])
            Issue.record("let in without the key or a password")
        } catch {
            #expect(http().status(of: error) == 401)
        }
        let sessions = try await http().request(method: "GET", url: address + "/api/sessions", body: "", headers: [:])
        #expect(Envelope.decode(sessions)?.type == "welcome")
        // The reset is the app's own.
        _ = server.createAdminToken()
        let reset = try await http().request(method: "POST", url: address + "/api/admin-token/reset", body: "", headers: [:])
        #expect(parseJSON(reset)?["token"].string?.isEmpty == false)
    }

    /// The app showing no key (0.65.1's agent lost it from the keychain as
    /// it kept it), with SSH clients off: refused once, the server keeps
    /// its key again as it refuses, and the app's service asks again with
    /// the key it now reads. The menu's reset the same.
    @Test func theAppReadsTheKeyAgainAndIsLetInAfterARefusal() async throws {
        let keychain = MemorySecrets()
        keychain.set(AppKeyKeeper.name, Self.key)
        let agent = AppKeyKeeper(secrets: { keychain }, log: { _ in }, attempts: 1, pause: {})
        #expect(agent.serverKey() == Self.key)
        server.appKeyAskedAgain = { agent.reconciled($0) }
        keychain.set(AppKeyKeeper.name, nil)
        let app = AppKeyKeeper(secrets: { keychain }, log: { _ in }, attempts: 1, pause: {})
        let http = SocketFileHTTPService(connect: { await POSIXUnixSocket.connect($0) },
                                         headers: { app.shown.map { [VisorServer.appKeyHeader: $0] } ?? [:] })
        server.settings.sshEnabled = false
        try await waitForTheSocketFile()

        let sessions = try await http.request(method: "GET", url: address + "/api/sessions", body: "", headers: [:])
        #expect(Envelope.decode(sessions)?.type == "welcome")
        #expect(app.shown == Self.key)
        // Lost again: the reset, refused once, is asked again and taken.
        keychain.set(AppKeyKeeper.name, nil)
        server.appKeyLastAsked = nil
        _ = server.createAdminToken()
        let reset = try await http.request(method: "POST", url: address + "/api/admin-token/reset", body: "", headers: [:])
        #expect(parseJSON(reset)?["token"].string?.isEmpty == false)
    }

    @Test func theLiveChannelOpensAndLogsInWithNoPassword() async throws {
        let sockets = channel()
        let id = sockets.open(url: try #require(ServerAddress(address)).socket, headers: [:])
        #expect(id > 0)
        #expect(try await sockets.next(id: id) == "open")
        sockets.send(id: id, text: Envelope.login(password: "", client: "socket-file-tests").encoded())
        let welcome = try await sockets.next(id: id)
        #expect(welcome.hasPrefix("message "))
        #expect(Envelope.decode(String(welcome.dropFirst(8)))?.type == "welcome")
        sockets.send(id: id, text: Envelope.ping().encoded())
        #expect(Envelope.decode(String(try await sockets.next(id: id).dropFirst(8)))?.type == "pong")
        sockets.disconnect(id: id)
        #expect(try await sockets.next(id: id).hasPrefix("close"))
    }

    @Test func theChannelWithoutTheKeyWantsThePasswordWithSSHClientsOff() async throws {
        server.settings.sshEnabled = false
        try await waitForTheSocketFile()
        let sockets = channel(showingKey: false)
        let id = sockets.open(url: try #require(ServerAddress(address)).socket, headers: [:])
        #expect(try await sockets.next(id: id) == "open")
        sockets.send(id: id, text: Envelope.login(password: "", client: "socket-file-tests").encoded())
        let refused = try await sockets.next(id: id)
        #expect(Envelope.decode(String(refused.dropFirst(8)))?.message == "Wrong password")
    }

    @Test func nothingAtTheSocketFileIsAnError() async throws {
        let nowhere = SocketFileURL.address(socket: "/tmp/visor-nothing-\(UUID().uuidString).sock")
        do {
            _ = try await http().request(method: "GET", url: nowhere + "/api/hello", body: "", headers: [:])
            Issue.record("answered from nowhere")
        } catch {
            #expect(http().status(of: error) == 0)
        }
        let sockets = channel()
        let id = sockets.open(url: try #require(ServerAddress(nowhere)).socket, headers: [:])
        #expect(try await sockets.next(id: id).hasPrefix("error"))
    }

    @Test func theHostsServicesSendSocketFileURLsThereAndTheRestAsBefore() async throws {
        let other = ElsewhereHTTP()
        let routed = SocketFileRoutedHTTPService(socketFile: http(), other: other)
        _ = try await routed.request(method: "GET", url: "https://mac.example/api/hello", body: "", headers: [:])
        #expect(other.asked.withLock { $0 } == ["https://mac.example/api/hello"])
        let hello = try await routed.request(method: "GET", url: address + "/api/hello", body: "", headers: [:])
        #expect(Envelope.decode(hello)?.id == server.id)
        #expect(other.asked.withLock { $0 }.count == 1, "the socket file's went there")

        let routedChannel = SocketFileRoutedSocketService(socketFile: channel(), other: ElsewhereSockets())
        let id = routedChannel.open(url: try #require(ServerAddress(address)).socket, headers: [:])
        #expect(try await routedChannel.next(id: id) == "open")
        let elsewhere = routedChannel.open(url: "wss://mac.example/", headers: [:])
        #expect(try await routedChannel.next(id: elsewhere) == "elsewhere")
    }
}
}

/// The host's own HTTP service, as far as the routing goes: what it was
/// asked for.
private final class ElsewhereHTTP: VisorHTTPService {
    let asked = Mutex<[String]>([])
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        asked.withLock { $0.append(url) }
        return "{}"
    }
}

/// The host's own socket service: one event for every socket.
@MainActor
private final class ElsewhereSockets: VisorSocketService {
    func open(url: String) -> Int32 { 7 }
    func send(id: Int32, text: String) {}
    func disconnect(id: Int32) {}
    func next(id: Int32) async throws -> String { "elsewhere" }
    func delay(milliseconds: Int32) async {}
}
