// Who gets in: a bearer that is the password, or a token `hello` issued
// — and nobody else, except on the socket file only this user can open,
// where a client through the computer's own SSH is already signed in.
// Without a password the server does not listen at all; with one it
// listens on this computer alone, or on every interface when opened to
// the network, and tells clients an address accordingly.

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
        server.settings.reachableFromNetwork = true
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(server.listening)
        if let first = ServerPlatform.current.host.addresses().first {
            XCTAssertEqual(server.reachableAddress, "http://\(first):7997")
        } else {
            XCTAssertNil(server.reachableAddress, "no network at all")
        }
        server.settings.publicAddress = "https://proxy.example.com/visor"
        XCTAssertEqual(server.reachableAddress, "https://proxy.example.com/visor")
        XCTAssertEqual(server.connectionCode?.host, "https://proxy.example.com/visor")
        // Kept, for the next launch.
        XCTAssertEqual(ServerSettings.kept(at: VisorServer.settingsURL).publicAddress, "https://proxy.example.com/visor")
    }

    func testConnectionCodeCarriesAddressAndPassword() async {
        XCTAssertNil(server.connectionCode)
        server.password = "pearl-grove"
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

        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"reachableFromNetwork":true}"#.utf8))
        XCTAssertTrue(older.sshEnabled)
        XCTAssertTrue(older.reachableFromNetwork)
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

        // As the client reaches it: nc -U on the computer, HTTP through it.
        let answer = try await Self.through(path, "GET /api/hello HTTP/1.1\r\nHost: visor\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200"), answer)
        XCTAssertTrue(answer.contains("\"hello\""), answer)

        server.settings.sshEnabled = false
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Sends `text` to the socket file with `nc -U` and takes what comes back.
    private static func through(_ path: String, _ text: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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
