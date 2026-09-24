// Who gets in: a request the road names as the owner's, a bearer that is
// the password, or a token `hello` issued — and nobody else. Without a
// password the server does not listen at all.

import VisorProtocol
@testable import VisorServer
import XCTest

/// A road that names whoever the test says and records
/// whether it was asked to front.
final class FakeExposure: ServerExposure {
    let title = "Fake"
    let installed = true
    var owner: String? = "owner@example.com"
    var fronted = false
    func address() -> String? { "this-mac.example.ts.net" }
    func identity() -> String? { owner }
    func requester(headers: [String: String]) -> String? { headers["x-fake-login"] }
    func fronts(port: UInt16) -> Bool { fronted }
    func front(port: UInt16) -> String { fronted = true; return "" }
}

@MainActor
final class AuthTests: XCTestCase {
    private var server: VisorServer!
    private var exposure: FakeExposure!

    override func setUp() {
        super.setUp()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-auth-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        UserDefaults.standard.removeObject(forKey: "visor.password")
        server = VisorServer(port: 7997)
        exposure = FakeExposure()
        server.exposure = exposure
    }

    override func tearDown() {
        server.stop()
        UserDefaults.standard.removeObject(forKey: "visor.password")
        super.tearDown()
    }

    private func request(_ path: String, bearer: String? = nil, login: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        if let login { headers["x-fake-login"] = login }
        return HTTPRequest(method: "GET", path: path, headers: headers, body: "")
    }

    func testNoPasswordMeansNoServer() {
        XCTAssertEqual(server.password, "")
        server.start()
        XCTAssertFalse(server.listening)
        XCTAssertFalse(exposure.fronted)
        // Nothing gets in either way while there is no password.
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "")).status, 401)
    }

    func testSettingThePasswordStartsAndFronts() async {
        server.password = "pearl-grove"
        // The listener comes up asynchronously; the front is put in place
        // off the main thread.
        for _ in 0..<50 where !(server.listening && exposure.fronted) { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(server.listening)
        XCTAssertTrue(exposure.fronted)
    }

    func testOwnerPasswordAndTokenGetIn() async {
        server.password = "pearl-grove"
        for _ in 0..<50 where server.hostLogin == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(server.hostLogin, "owner@example.com")

        XCTAssertEqual(server.route(request("/api/sessions")).status, 401)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "wrong")).status, 401)
        XCTAssertEqual(server.route(request("/api/sessions", login: "someone@else.com")).status, 401)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: "pearl-grove")).status, 200)
        XCTAssertEqual(server.route(request("/api/sessions", login: "owner@example.com")).status, 200)

        // hello gives the owner a token the socket (and further calls) take.
        let hello = server.route(request("/api/hello", login: "owner@example.com"))
        XCTAssertEqual(hello.status, 200)
        let envelope = Envelope.decode(hello.body)
        XCTAssertEqual(envelope?.type, "hello")
        XCTAssertEqual(envelope?.login, "owner@example.com")
        let token = envelope?.token ?? ""
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: token)).status, 200)
        XCTAssertEqual(server.route(request("/api/sessions", bearer: token + "x")).status, 401)
        // A stranger gets no token.
        XCTAssertEqual(server.route(request("/api/hello", login: "someone@else.com")).status, 401)
    }

    func testOwnerIsToldToWaitWhileTailscaleStarts() async {
        // At login Tailscale may not have said whose this Mac is yet.
        exposure.owner = nil
        server.password = "pearl-grove"
        for _ in 0..<50 where server.serveError == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(server.serveError, "waiting for Fake")
        // The owner's device is told to come back, not to bring a password.
        XCTAssertEqual(server.route(request("/api/hello", login: "owner@example.com")).status, 503)
        // A request with no identity is still simply refused.
        XCTAssertEqual(server.route(request("/api/hello")).status, 401)

        // Tailscale answers; the next try learns the owner.
        exposure.owner = "owner@example.com"
        server.front()
        for _ in 0..<50 where server.hostLogin == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(server.hostLogin, "owner@example.com")
        // The name the menu shows is learned with it.
        XCTAssertEqual(server.address, "this-mac.example.ts.net")
        XCTAssertEqual(server.route(request("/api/hello", login: "owner@example.com")).status, 200)
    }

    func testTailscaleCLIRunsAsTheCLIWithoutATerminal() {
        // Started at login there is no terminal: the CLI must be told.
        XCTAssertEqual(TailscaleExposure.cliEnvironment(["HOME": "/Users/me"])["TERM"], "dumb")
        // A terminal's own TERM is left alone.
        XCTAssertEqual(TailscaleExposure.cliEnvironment(["TERM": "xterm-256color"])["TERM"], "xterm-256color")
    }

    func testConnectionCodeCarriesAddressAndPassword() async {
        XCTAssertNil(server.connectionCode)
        server.password = "pearl-grove"
        let code = server.connectionCode
        XCTAssertEqual(code?.host, "this-mac.example.ts.net")
        XCTAssertEqual(code?.password, "pearl-grove")
        XCTAssertEqual(code.flatMap { ConnectionCode(parsing: $0.encoded) }, code)
        XCTAssertEqual(code.flatMap { ConnectionCode(parsing: "  " + $0.link + "\n") }, code)
    }
}
