// Visor on the Mac as its own server's client: the server reached at its
// socket file (`http+unix://…`, SocketFileURL) as any computer is, there
// alone, with no password; and the server's own controls, as the menu and
// Settings call them (VisorAgentServer+Controls), each the REST call the
// server takes (docs/protocol.md), with what it answers and what it refuses.

import Foundation
import Synchronization
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// HTTP as a server's own controls answer: each call kept, its answer
/// scripted by method and path.
final class ControlsHTTP: VisorHTTPService {
    struct Call: Equatable {
        let method: String
        let url: String
        let body: String
        let headers: [String: String]
    }

    private let kept = Mutex<[Call]>([])
    var calls: [Call] { kept.withLock { $0 } }
    let answers: [String: Result<String, ScriptedFailure>]

    init(answers: [String: Result<String, ScriptedFailure>]) { self.answers = answers }

    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await request(method: method, url: url, body: body, headers: ["Authorization": "Bearer " + authorization])
    }

    func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        kept.withLock { $0.append(Call(method: method, url: url, body: body, headers: headers)) }
        let path = url.components(separatedBy: "/api").last ?? ""
        guard let answer = answers["\(method) \(path)"] else { throw ScriptedFailure(status: 404, body: #"{"error":"not found"}"#) }
        return try answer.get()
    }

    func status(of error: Error) -> Int? { (error as? ScriptedFailure)?.status }
    func body(of error: Error) -> String? { (error as? ScriptedFailure)?.body }
}

@MainActor
final class ServerControlsClientTests: XCTestCase {
    private var previousHTTP: (any VisorHTTPService)?
    private static let socket = "/Users/me/.visor/server.sock"
    private var address: String { SocketFileURL.address(socket: Self.socket) }

    override func setUp() async throws {
        try await super.setUp()
        previousHTTP = VisorHost.http
    }

    override func tearDown() async throws {
        VisorHost.http = previousHTTP
    }

    /// This Mac's own server, as the app holds it.
    private var record: AgentServerRecord {
        AgentServerRecord(name: "Mini", address: address, serverID: "mini-id", authentication: NoAuthenticator.name)
    }

    private static func controlsJSON(password: String = "pw", lan: Bool = false, notice: String? = nil) -> String {
        var controls = ServerControls()
        controls.host = "Mini"
        controls.id = "mini-id"
        controls.version = "0.62.7"
        controls.password = password
        controls.listening = !password.isEmpty
        controls.updateNotice = notice
        controls.settings.lan = lan
        controls.codes = ConnectionCodes(qr: "qr-code", http: "http-code")
        return controls.json.encoded()
    }

    // MARK: The address

    func testASocketFileIsAnAddressLikeAnyOther() throws {
        XCTAssertEqual(address, "http+unix://%2FUsers%2Fme%2F.visor%2Fserver.sock")
        let parsed = try XCTUnwrap(ServerAddress(address))
        XCTAssertTrue(parsed.isSocketFile)
        XCTAssertEqual(parsed.api, address + "/api")
        XCTAssertEqual(parsed.socket, "ws+unix://%2FUsers%2Fme%2F.visor%2Fserver.sock/")
        XCTAssertEqual(parsed.display, Self.socket)
        XCTAssertEqual(SocketFileURL.split(parsed.api + "/hello")?.socket, Self.socket)
        XCTAssertEqual(SocketFileURL.split(parsed.api + "/hello")?.path, "/api/hello")
        XCTAssertEqual(SocketFileURL.split(parsed.socket)?.path, "/")
        XCTAssertNil(SocketFileURL.split("http://127.0.0.1:7433/api/hello"))
        XCTAssertFalse(ServerAddress("http://127.0.0.1:7433")?.isSocketFile ?? true)
        // A path with spaces and more comes back as it was.
        let odd = "/tmp/a b/ç%.sock"
        XCTAssertEqual(SocketFileURL.split(SocketFileURL.address(socket: odd) + "/api/x?y=1")?.socket, odd)
    }

    /// At its socket file the server is reached there alone: none of the
    /// paths it says it has, no SSH, no password.
    func testTheSocketFileIsTheOnlyPathTried() {
        var record = record
        record.paths = ["ssh://me@192.168.1.52", "http://127.0.0.1:7433", "http://192.168.1.52:7433"]
        XCTAssertTrue(record.isSocketFile)
        XCTAssertEqual(AgentServerConnection(record: record).pathsToTry(), [address])
    }

    // MARK: The controls

    func testTheControlsAreReadAndChangedOverREST() async throws {
        let http = ControlsHTTP(answers: ["GET /settings": .success(Self.controlsJSON()),
                                          "PUT /settings": .success(Self.controlsJSON(password: "new", lan: true))])
        VisorHost.http = http
        let server = VisorAgentServer(record: record)
        let read = try await server.controls()
        XCTAssertEqual(read.password, "pw")
        XCTAssertEqual(read.id, "mini-id")
        XCTAssertEqual(read.codes?.http, "http-code")
        XCTAssertTrue(read.hasPassword && read.listening)
        let changed = try await server.change(ServerControlsChange(password: "new", lan: true))
        XCTAssertTrue(changed.settings.lan)
        XCTAssertEqual(changed.password, "new")
        XCTAssertEqual(http.calls.map(\.method), ["GET", "PUT"])
        XCTAssertEqual(http.calls[0].url, address + "/api/settings")
        XCTAssertEqual(parseJSON(http.calls[1].body)?["password"].string, "new")
        XCTAssertEqual(parseJSON(http.calls[1].body)?["lan"].bool, true)
        XCTAssertTrue(parseJSON(http.calls[1].body)?["vpn"].isNull ?? false, "only the fields changed")
        // Signed in to by nothing: the socket file lets this user in.
        XCTAssertNil(http.calls[0].headers["Authorization"])
    }

    func testTheControlsJSONRoundTrips() throws {
        var controls = try XCTUnwrap(parseJSON(Self.controlsJSON(notice: "0.62.8 did not stay up")).flatMap(ServerControls.init(json:)))
        XCTAssertEqual(controls.updateNotice, "0.62.8 did not stay up")
        controls.detachingSet = false
        controls.sshPaths = ["ssh://me@mini.local"]
        XCTAssertEqual(ServerControls(json: controls.json), controls)
        XCTAssertNil(ServerControls(json: parseJSON(#"{"type":"error","error":"no"}"#) ?? .null))
        let change = ServerControlsChange(authentication: "none", tlsIdentityPath: "/tmp/id.p12", tlsPassword: "x")
        XCTAssertEqual(ServerControlsChange(json: change.json), change)
    }

    func testTheMenusCallsAreTheServersRoutes() async throws {
        let http = ControlsHTTP(answers: ["POST /admin-token": .success(#"{"token":"first"}"#),
                                          "POST /admin-token/reset": .success(#"{"token":"second"}"#),
                                          "POST /keys/rotate": .success(#"{"current":"k2","kids":["k2"],"grace":[]}"#),
                                          "POST /push/key": .success(#"{"type":"push"}"#),
                                          "POST /push/test": .success(#"{"type":"push"}"#),
                                          "POST /quit": .success(#"{"type":"quit"}"#),
                                          "POST /restart": .success(#"{"type":"restart","sessions":[]}"#),
                                          "GET /session-table": .success(#"{"type":"sessionTable","text":"| Computer |"}"#)])
        VisorHost.http = http
        let server = VisorAgentServer(record: record)
        let made = try await server.createAdminToken()
        XCTAssertEqual(made, "first")
        let reset = try await server.resetAdminToken()
        XCTAssertEqual(reset, "second")
        try await server.rotateSigningKeys(emergency: false)
        try await server.rotateSigningKeys(emergency: true)
        try await server.setPushKey(pem: "-----BEGIN-----", keyID: "ABCDEFGHIJ", teamID: "KLMNOPQRST")
        try await server.sendTestPush()
        let table = try await server.sessionTable()
        XCTAssertEqual(table, "| Computer |")
        try await server.restartServer(installing: "/tmp/Visor.app")
        try await server.quitServer()
        XCTAssertEqual(http.calls.map { "\($0.method) \($0.url.replacingOccurrences(of: address, with: ""))" },
                       ["POST /api/admin-token", "POST /api/admin-token/reset", "POST /api/keys/rotate", "POST /api/keys/rotate",
                        "POST /api/push/key", "POST /api/push/test", "GET /api/session-table", "POST /api/restart", "POST /api/quit"])
        XCTAssertNil(parseJSON(http.calls[2].body)?["dropPrevious"].bool, "an ordinary rotation drops nothing")
        XCTAssertEqual(parseJSON(http.calls[3].body)?["dropPrevious"].bool, true)
        XCTAssertEqual(parseJSON(http.calls[4].body)?["keyID"].string, "ABCDEFGHIJ")
        XCTAssertEqual(parseJSON(http.calls[7].body)?["path"].string, "/tmp/Visor.app")
    }

    /// What the server refuses comes back in its own words, for the alert.
    func testARefusalSaysWhatTheServerSaid() async throws {
        let refused = #"{"type":"error","message":"The admin token is reset from Visor's menu on this Mac, or rotated with the current one."}"#
        VisorHost.http = ControlsHTTP(answers: ["POST /admin-token/reset": .failure(ScriptedFailure(status: 403, body: refused)),
                                                "GET /settings": .success(#"{"error":"no"}"#)])
        let server = VisorAgentServer(record: record)
        do {
            _ = try await server.resetAdminToken()
            XCTFail("the refusal was taken")
        } catch {
            XCTAssertEqual(VisorAgentServer.problem(error), "The admin token is reset from Visor's menu on this Mac, or rotated with the current one.")
        }
        do {
            _ = try await server.controls()
            XCTFail("an error was taken for the settings")
        } catch {
            XCTAssertEqual(VisorAgentServer.problem(error), "no")
        }
    }
}
