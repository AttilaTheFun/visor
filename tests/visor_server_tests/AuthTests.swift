// Who gets in: a bearer that is the password, or a token `hello` issued
// — and nobody else. Without a password the server does not listen at
// all; with one it listens on this computer alone, or on every interface
// when opened to the network, and tells clients an address accordingly.

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
        server = VisorServer(port: 7997)
    }

    override func tearDown() async throws {
        server.stop()
        UserDefaults.standard.removeObject(forKey: "visor.password")
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
}
