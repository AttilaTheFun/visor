// Who gets in: a bearer that is the password, or a token `hello` issued
// — and nobody else, except on the socket file only this user can open,
// where a client through the computer's own SSH is already signed in.
// Without a password the server does not listen at all; with one it
// listens on this computer alone, or on every interface when opened to
// the network, and tells clients an address accordingly.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import VisorProtocol
@testable import VisorServer
import Synchronization
import VisorSystem
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class AuthTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-auth-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        // Never the real keychain.
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-auth-\(getpid()).sock"
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
        VisorServer.socketPathOverride = nil
    }

    private func request(_ path: String, bearer: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        return HTTPRequest(method: "GET", path: path, headers: headers, body: "")
    }

    @Test func testNoPasswordMeansNoServer() {
        #expect(server.password == "")
        server.start()
        #expect(!server.listening)
        // Nothing gets in while there is no password.
        #expect((server.route(request("/api/sessions", bearer: "")).status) == 401)
    }

    @Test func testSettingThePasswordStarts() async {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening)
        // On this computer alone, nothing is said to clients about where.
        #expect(server.reachableAddress == nil)
        #expect(server.connectionCode == nil)
    }

    /// A refusal says whose computer this is, as hello does: a client that
    /// reached it at another computer's path knows the path is wrong.
    @Test func testARefusalSaysWhoseComputerItIs() {
        server.password = "pearl-grove"
        let refused = server.route(request("/api/hello", bearer: "wrong"))
        #expect(refused.status == 401)
        #expect((Envelope.decode(refused.body, defaultType: "reply")?.id) == server.id)
    }

    @Test func testPasswordAndTokenGetIn() async {
        server.password = "pearl-grove"
        #expect((server.route(request("/api/sessions")).status) == 401)
        #expect((server.route(request("/api/sessions", bearer: "wrong")).status) == 401)
        // A header a front might add names nobody to this server.
        var named = request("/api/sessions")
        named.headers["x-forwarded-user"] = "owner@example.com"
        #expect(server.route(named).status == 401)
        #expect((server.route(request("/api/sessions", bearer: "pearl-grove")).status) == 200)

        // hello gives a token the socket (and further calls) take.
        let hello = server.route(request("/api/hello", bearer: "pearl-grove"))
        #expect(hello.status == 200)
        let envelope = Envelope.decode(hello.body)
        #expect((envelope?.type) == "hello")
        let token = envelope?.token ?? ""
        #expect(!token.isEmpty)
        #expect((server.route(request("/api/sessions", bearer: token)).status) == 200)
        #expect((server.route(request("/api/sessions", bearer: token + "x")).status) == 401)
        // Without the password, no token.
        #expect((server.route(request("/api/hello")).status) == 401)
    }

    /// hello says whether clients may keep the sessions' messages on their
    /// disk: only when they may not, so a server from before reads as yes.
    @Test func testHelloAsksClientsToKeepMessagesInMemoryOnlyWhenSet() async throws {
        server.password = "pearl-grove"
        let kept = Envelope.decode(server.route(request("/api/hello", bearer: "pearl-grove")).body)
        #expect((kept?.keepMessages) == nil)
        server.settings.clientsKeepMessages = false
        let inMemory = Envelope.decode(server.route(request("/api/hello", bearer: "pearl-grove")).body)
        #expect((inMemory?.keepMessages) == false)
        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"lan":true}"#.utf8))
        #expect(older.clientsKeepMessages, "a settings file from before lets them")
    }

    /// Opened to the network, the server tells clients its first address
    /// with the port; an address set by hand is told instead.
    @Test func testTheAddressClientsAreTold() async {
        server.password = "pearl-grove"
        server.settings.lan = true
        server.settings.vpn = true
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening)
        if ServerPlatform.current.host.addresses().isEmpty {
            #expect(server.reachableAddress == nil, "no network at all")
        } else {
            #expect(server.reachableAddress == server.httpPaths.first)
            #expect(server.reachableAddress?.hasSuffix(":\(server.port)") == true)
        }
        // Each path admits its own connections, and only while on.
        #expect(server.admits(localAddress: nil))
        #expect(server.admits(localAddress: "127.0.0.1"))
        #expect(server.admits(localAddress: "192.168.1.20"))
        #expect(server.admits(localAddress: "100.64.0.11"))
        server.settings.lan = false
        #expect(!server.admits(localAddress: "192.168.1.20"))
        #expect(server.admits(localAddress: "100.64.0.11"), "a VPN's range")
        server.settings.vpn = false
        #expect(!server.admits(localAddress: "100.64.0.11"))
        #expect(server.admits(localAddress: "127.0.0.1"), "this computer always")
        #expect(NetworkAddress(address: "10.0.0.5", interface: "utun3").kind == .vpn)
        #expect(NetworkAddress.isLinkLocal("169.254.179.38"))
        #expect(!(ServerPlatform.current.host.networkAddresses().contains { NetworkAddress.isLinkLocal($0.address) }))
        #expect(NetworkAddress(address: "192.168.1.5", interface: "en0").kind == .lan)
        server.settings.lan = true
        server.settings.vpn = true
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        #expect(server.reachableAddress == "https://proxy.example.com/visor")
        #expect((server.connectionCode?.host) == "https://proxy.example.com/visor")
        // Kept, for the next launch.
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).publicAddress == "https://proxy.example.com/visor")
    }

    @Test func testConnectionCodeCarriesAddressAndPassword() async {
        #expect(server.connectionCode == nil)
        server.password = "pearl-grove"
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "this-mac.example.ts.net"
        let code = server.connectionCode
        #expect((code?.host) == "this-mac.example.ts.net")
        #expect((code?.password) == "pearl-grove")
        #expect((code.flatMap { ConnectionCode(parsing: $0.encoded) }) == code)
        #expect((code.flatMap { ConnectionCode(parsing: "  " + $0.link + "\n") }) == code)
    }

    /// A request on a trusted connection (the socket file) needs no
    /// bearer; a login there needs no password; the setting decides
    /// whether the file is served at all, and a settings file from
    /// before it reads as served.
    @Test func testSSHClientsAreTrustedWithoutAPassword() async throws {
        server.password = "pearl-grove"
        var trusted = request("/api/sessions")
        trusted.trusted = true
        #expect(server.route(trusted).status == 200)
        var hello = request("/api/hello")
        hello.trusted = true
        let answer = server.route(hello)
        #expect(answer.status == 200)
        #expect(!(Envelope.decode(answer.body)?.token?.isEmpty ?? true))

        let stream = RecordingStream()
        let client = ClientConnection(stream: stream)
        client.trusted = true
        server.handle(Envelope(type: "login"), from: client)
        #expect(client.authenticated)
        let plain = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: plain)
        #expect(!plain.authenticated)

        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"reachableFromNetwork":true,"publicAddress":"https://p.example"}"#.utf8))
        #expect(older.sshEnabled)
        #expect(older.lan && older.vpn, "the network was both paths")
        #expect(older.proxyEnabled, "an address set was a proxy in use")
        var off = ServerSettings()
        off.sshEnabled = false
        let kept = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(off))
        #expect(!kept.sshEnabled)
    }

    /// The socket file is there while SSH clients are let in, closed to
    /// everyone but its owner, answers hello with no bearer, and goes
    /// when the setting is turned off.
    @Test func testTheSocketFileAnswersWithoutABearer() async throws {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        let path = VisorServer.socketPath
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(FileManager.default.fileExists(atPath: path), Comment(rawValue: path))
        // Closed to others a moment after it is made (bound, then its mode
        // set): read once that has happened, not in between.
        var mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        for _ in 0..<50 where mode.map({ $0 & 0o777 }) != 0o600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        }
        #expect((mode.map { $0 & 0o777 }) == 0o600)

        // As the client reaches it (`nc -U` on the computer): a connection
        // to the file, HTTP through it, no bearer.
        let answer = await Self.through(path, "GET /api/hello HTTP/1.1\r\nHost: visor\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 200"), Comment(rawValue: answer))
        #expect(answer.contains("\"hello\""), Comment(rawValue: answer))

        server.settings.sshEnabled = false
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Sends `text` down a connection to the socket file and takes what
    /// comes back, off the main actor (the server answers there).
    private static func through(_ path: String, _ text: String) async -> String {
        await Task.detached {
            #if canImport(Glibc)
            let kind = Int32(SOCK_STREAM.rawValue)
            #else
            let kind = SOCK_STREAM
            #endif
            let fd = socket(AF_UNIX, kind, 0)
            guard fd >= 0 else { return "no socket: \(errno)" }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return "not connected: \(errno)" }
            _ = text.withCString { write(fd, $0, strlen($0)) }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                answer.append(contentsOf: buffer[..<count])
            }
            return String(decoding: answer, as: UTF8.self)
        }.value
    }
    /// Set to ask nothing, the server lets in whoever reaches it — no
    /// bearer, no password at login — and serves with no password set.
    @Test func testAServerAskingNothingLetsEveryoneIn() async {
        server.settings.authentication = "none"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening, "no password, and it serves")
        #expect((server.route(request("/api/sessions")).status) == 200)
        #expect((server.route(request("/api/hello")).status) == 200)
        let client = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: client)
        #expect(client.authenticated)
        server.settings.authentication = "password"
        #expect((server.route(request("/api/sessions")).status) == 401)
    }
    /// A client that is in hands its SSH key over: kept once in the
    /// authorized keys, the folder and file closed to others; junk is
    /// refused; a stranger gets nothing. The connection code carries the
    /// server's paths.
    @Test func testADeviceAuthorizesItsSSHKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-keys-" + UUID().uuidString)
        VisorServer.authorizedKeysPathOverride = folder.appendingPathComponent("ssh/authorized_keys").path
        defer { VisorServer.authorizedKeysPathOverride = nil }
        server.password = "pearl-grove"
        func post(_ line: String, bearer: String? = "pearl-grove") -> Int {
            var body = Envelope(type: "ssh")
            body.text = line
            var headers: [String: String] = [:]
            if let bearer { headers["authorization"] = "Bearer " + bearer }
            return server.route(HTTPRequest(method: "POST", path: "/api/ssh/keys", headers: headers, body: body.encoded())).status
        }
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGqz1sYyl1Y1kK5lN0w0C5oZ6QwYyq3lQ1kDnq1Z2y7A visor"
        #expect(post(key, bearer: nil) == 401)
        #expect(post(key) == 200)
        #expect(post(key) == 200, "the same key again is no change")
        #expect(post("ssh-ed25519 AAAAother visor") == 200)
        #expect(post("rm -rf /") == 400)
        #expect(post("ssh-ed25519 AAAA$not$base64") == 400)
        #expect(post("ssh-ed25519") == 400)
        let kept = try String(contentsOfFile: VisorServer.authorizedKeysPath, encoding: .utf8)
        #expect(kept == (key + "\nssh-ed25519 AAAAother visor\n"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: VisorServer.authorizedKeysPath)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("ssh").path)[.posixPermissions] as? Int
        #expect((fileMode.map { $0 & 0o777 }) == 0o600)
        #expect((folderMode.map { $0 & 0o777 }) == 0o700)

        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        server.settings.sshEnabled = true
        let code = try #require(server.connectionCode)
        #expect(code.host == "https://proxy.example.com/visor")
        #expect(code.paths == (server.ownAddresses.filter { $0 != code.host }))
        #expect((ConnectionCode(parsing: code.encoded)?.paths) == code.paths)
    }
}
}

/// A stream that keeps what is sent to it.
@MainActor
private final class RecordingStream: ByteStream {
    var sent: [Data] = []
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() {}
}
