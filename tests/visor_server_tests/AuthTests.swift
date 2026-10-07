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
import XCTest

@MainActor
final class AuthTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-auth-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        UserDefaults.standard.removeObject(forKey: "visor.password")
        // Never the real keychain.
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-auth-\(getpid()).sock"
        server = VisorServer(port: 7997)
    }

    override func tearDown() async throws {
        server.stop()
        UserDefaults.standard.removeObject(forKey: "visor.password")
        VisorServer.socketPathOverride = nil
    }

    private func request(_ path: String, bearer: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        return HTTPRequest(method: "GET", path: path, headers: headers, body: "")
    }

    func testNoPasswordMeansNoServer() {
        XCTAssertEqual(server.password, "")
        server.start()
        XCTAssertFalse(server.listening)
        // Nothing gets in while there is no password.
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "")).status, 401)
    }

    func testSettingThePasswordStarts() async {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(server.listening)
        // On this computer alone, nothing is said to clients about where.
        XCTAssertNil(server.reachableAddress)
        XCTAssertNil(server.connectionCode)
    }

    func testPasswordAndTokenGetIn() async {
        server.password = "pearl-grove"
        XCTAssertEqual(server.route(request("/api/sessions")).status, 401)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "wrong")).status, 401)
        // A header a front might add names nobody to this server.
        var named = request("/api/sessions")
        named.headers["x-forwarded-user"] = "owner@example.com"
        XCTAssertEqual(server.route(named).status, 401)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "pearl-grove")).status, 200)

        // hello gives a token the socket (and further calls) take.
        let hello = server.route(request("/api/hello", bearer: "pearl-grove"))
        XCTAssertEqual(hello.status, 200)
        let envelope = Envelope.decode(hello.body)
        XCTAssertEqual(envelope?.type, "hello")
        let token = envelope?.token ?? ""
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: token)).status, 200)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: token + "x")).status, 401)
        // Without the password, no token.
        XCTAssertEqual(server.route(request("/api/hello")).status, 401)
    }

    /// Opened to the network, the server tells clients its first address
    /// with the port; an address set by hand is told instead.
    func testTheAddressClientsAreTold() async {
        server.password = "pearl-grove"
        server.settings.lan = true
        server.settings.vpn = true
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(server.listening)
        if ServerPlatform.current.host.addresses().isEmpty {
            XCTAssertNil(server.reachableAddress, "no network at all")
        } else {
            XCTAssertEqual(server.reachableAddress, server.httpPaths.first)
            XCTAssertTrue(server.reachableAddress?.hasSuffix(":7997") == true)
        }
        // Each path admits its own connections, and only while on.
        XCTAssertTrue(server.admits(localAddress: nil))
        XCTAssertTrue(server.admits(localAddress: "127.0.0.1"))
        XCTAssertTrue(server.admits(localAddress: "192.168.1.20"))
        XCTAssertTrue(server.admits(localAddress: "100.90.45.11"))
        server.settings.lan = false
        XCTAssertFalse(server.admits(localAddress: "192.168.1.20"))
        XCTAssertTrue(server.admits(localAddress: "100.90.45.11"), "a VPN's range")
        server.settings.vpn = false
        XCTAssertFalse(server.admits(localAddress: "100.90.45.11"))
        XCTAssertTrue(server.admits(localAddress: "127.0.0.1"), "this computer always")
        XCTAssertEqual(NetworkAddress(address: "10.0.0.5", interface: "utun3").kind, .vpn)
        XCTAssertTrue(NetworkAddress.isLinkLocal("169.254.179.38"))
        XCTAssertFalse(ServerPlatform.current.host.networkAddresses().contains { NetworkAddress.isLinkLocal($0.address) })
        XCTAssertEqual(NetworkAddress(address: "192.168.1.5", interface: "en0").kind, .lan)
        server.settings.lan = true
        server.settings.vpn = true
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        XCTAssertEqual(server.reachableAddress, "https://proxy.example.com/visor")
        XCTAssertEqual(server.connectionCode?.host, "https://proxy.example.com/visor")
        // Kept, for the next launch.
        XCTAssertEqual(ServerSettings.kept(at: VisorServer.settingsURL).publicAddress, "https://proxy.example.com/visor")
    }

    func testConnectionCodeCarriesAddressAndPassword() async {
        XCTAssertNil(server.connectionCode)
        server.password = "pearl-grove"
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "this-mac.example.ts.net"
        let code = server.connectionCode
        XCTAssertEqual(code?.host, "this-mac.example.ts.net")
        XCTAssertEqual(code?.password, "pearl-grove")
        XCTAssertEqual(code.flatMap { ConnectionCode(parsing: $0.encoded) }, code)
        XCTAssertEqual(code.flatMap { ConnectionCode(parsing: "  " + $0.link + "\n") }, code)
    }

    /// A request on a trusted connection (the socket file) needs no
    /// bearer; a login there needs no password; the setting decides
    /// whether the file is served at all, and a settings file from
    /// before it reads as served.
    func testSSHClientsAreTrustedWithoutAPassword() async throws {
        server.password = "pearl-grove"
        var trusted = request("/api/sessions")
        trusted.trusted = true
        XCTAssertEqual(server.route(trusted).status, 200)
        var hello = request("/api/hello")
        hello.trusted = true
        let answer = server.route(hello)
        XCTAssertEqual(answer.status, 200)
        XCTAssertFalse(Envelope.decode(answer.body)?.token?.isEmpty ?? true)

        let stream = RecordingStream()
        let client = ClientConnection(stream: stream)
        client.trusted = true
        server.handle(Envelope(type: "login"), from: client)
        XCTAssertTrue(client.authenticated)
        let plain = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: plain)
        XCTAssertFalse(plain.authenticated)

        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"reachableFromNetwork":true,"publicAddress":"https://p.example"}"#.utf8))
        XCTAssertTrue(older.sshEnabled)
        XCTAssertTrue(older.lan && older.vpn, "the network was both paths")
        XCTAssertTrue(older.proxyEnabled, "an address set was a proxy in use")
        var off = ServerSettings()
        off.sshEnabled = false
        let kept = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(kept.sshEnabled)
    }

    /// The socket file is there while SSH clients are let in, closed to
    /// everyone but its owner, answers hello with no bearer, and goes
    /// when the setting is turned off.
    func testTheSocketFileAnswersWithoutABearer() async throws {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        let path = VisorServer.socketPath
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)

        // As the client reaches it (`nc -U` on the computer): a connection
        // to the file, HTTP through it, no bearer.
        let answer = await Self.through(path, "GET /api/hello HTTP/1.1\r\nHost: visor\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200"), answer)
        XCTAssertTrue(answer.contains("\"hello\""), answer)

        server.settings.sshEnabled = false
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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
    func testAServerAskingNothingLetsEveryoneIn() async {
        server.settings.authentication = "none"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(server.listening, "no password, and it serves")
        XCTAssertEqual(server.route(request("/api/sessions")).status, 200)
        XCTAssertEqual(server.route(request("/api/hello")).status, 200)
        let client = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: client)
        XCTAssertTrue(client.authenticated)
        server.settings.authentication = "password"
        XCTAssertEqual(server.route(request("/api/sessions")).status, 401)
    }
    /// A client that is in hands its SSH key over: kept once in the
    /// authorized keys, the folder and file closed to others; junk is
    /// refused; a stranger gets nothing. The connection code carries the
    /// server's paths.
    func testADeviceAuthorizesItsSSHKey() throws {
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
        XCTAssertEqual(post(key, bearer: nil), 401)
        XCTAssertEqual(post(key), 200)
        XCTAssertEqual(post(key), 200, "the same key again is no change")
        XCTAssertEqual(post("ssh-ed25519 AAAAother visor"), 200)
        XCTAssertEqual(post("rm -rf /"), 400)
        XCTAssertEqual(post("ssh-ed25519 AAAA$not$base64"), 400)
        XCTAssertEqual(post("ssh-ed25519"), 400)
        let kept = try String(contentsOfFile: VisorServer.authorizedKeysPath, encoding: .utf8)
        XCTAssertEqual(kept, key + "\nssh-ed25519 AAAAother visor\n")
        let fileMode = try FileManager.default.attributesOfItem(atPath: VisorServer.authorizedKeysPath)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("ssh").path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode.map { $0 & 0o777 }, 0o600)
        XCTAssertEqual(folderMode.map { $0 & 0o777 }, 0o700)

        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        server.settings.sshEnabled = true
        let code = try XCTUnwrap(server.connectionCode)
        XCTAssertEqual(code.host, "https://proxy.example.com/visor")
        XCTAssertEqual(code.paths, server.ownAddresses.filter { $0 != code.host })
        XCTAssertEqual(ConnectionCode(parsing: code.encoded)?.paths, code.paths)
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
