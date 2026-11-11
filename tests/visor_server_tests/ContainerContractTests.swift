// What a server is told where it starts, and what it answers without
// credentials (docs/server-proxy.md, the server's contract): its
// environment and arguments (the arguments winning), its secrets read from
// files and passed on by their paths alone, the proxy it is given for
// pushes and MCP servers, and the health check a keep-alive asks.

import Foundation
import VisorProtocol
@testable import VisorServer
@testable import VisorServerCLI
import XCTest

@MainActor
final class ContainerContractTests: ServerTestCase {
    private var server: VisorServer!
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-contract-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        VisorServer.storeRoot = folder
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: Self.freePort())
        server.password = "pw"
    }

    private func secret(_ name: String, _ value: String) throws -> String {
        let file = folder.appendingPathComponent(name)
        try Data((value + "\n").utf8).write(to: file)
        return file.path
    }

    func testTheEnvironmentSaysWhereItIsAndTheArgumentsWin() throws {
        let password = try secret("visor-password", "hunter22")
        let token = try secret("visor-proxy", "tok-5f2a9c")
        let environment = ["VISOR_PORT": "7433", "VISOR_LISTEN": "0.0.0.0", "VISOR_PASSWORD_FILE": password,
                           "VISOR_FRONT": "http://127.0.0.1:17433,http://mac.tail:17433",
                           "VISOR_PROXY": "http://192.168.128.1:7434/", "VISOR_PROXY_TOKEN_FILE": token,
                           "VISOR_MCP": "shireworks, gh", "VISOR_UNRELATED": "x"]
        let options = try ServerOptions([], environment: environment)
        XCTAssertEqual(options.port, 7433)
        XCTAssertEqual(options.password, "hunter22", "read from its file, the line's end trimmed")
        XCTAssertEqual(options.proxy, "http://192.168.128.1:7434/")
        XCTAssertEqual(options.proxyToken, "tok-5f2a9c")
        XCTAssertEqual(options.mcp, ["shireworks", "gh"])
        XCTAssertEqual(options.settings.map { "\($0.0)=\($0.1)" },
                       ["lan=on", "vpn=on", "front=http://127.0.0.1:17433,http://mac.tail:17433"])
        // A run started from this one is given the files, never the secrets.
        let passed = options.arguments.joined(separator: " ")
        XCTAssertFalse(passed.contains("hunter22") || passed.contains("tok-5f2a9c"), passed)
        XCTAssertTrue(passed.contains("--password-file " + password) && passed.contains("--proxy-token-file " + token), passed)
        XCTAssertEqual(try ServerOptions(options.arguments).password, "hunter22", "the successor reads the same file")

        let given = try ServerOptions(["--port", "9000", "--listen", "loopback"], environment: environment)
        XCTAssertEqual(given.port, 9000, "the argument wins")
        XCTAssertEqual(given.settings.suffix(2).map { "\($0.0)=\($0.1)" }, ["lan=off", "vpn=off"], "applied after the environment's")
    }

    func testWhatItCanNotUseIsSaid() {
        XCTAssertThrowsError(try ServerOptions([], environment: ["VISOR_PORT": "seventy"]))
        XCTAssertThrowsError(try ServerOptions([], environment: ["VISOR_LISTEN": "sometimes"]))
        XCTAssertThrowsError(try ServerOptions([], environment: ["VISOR_PASSWORD_FILE": "/nowhere/visor-password"]))
        XCTAssertNoThrow(try ServerOptions([], environment: ["VISOR_PORT": "  "]), "an empty value is none")
    }

    func testTheHealthCheckAnswersWithoutCredentials() throws {
        let health = server.route(HTTPRequest(method: "GET", path: "/api/health", headers: [:], body: ""))
        XCTAssertEqual(health.status, 200)
        let body = try XCTUnwrap(parseJSON(health.body))
        XCTAssertEqual(body["ok"].bool, true)
        XCTAssertNotNil(body["version"].string)
        XCTAssertEqual(server.route(HTTPRequest(method: "GET", path: "/api/sessions", headers: [:], body: "")).status, 401,
                       "nothing else without them")
        XCTAssertNotEqual(server.route(HTTPRequest(method: "POST", path: "/api/health", headers: [:], body: "")).status, 200,
                          "asked, not sent to")
    }

    func testTheProxyGivenAtStartCarriesPushesAndTheNamedMCPServers() {
        server.settings.mcpEndpoints = [MCPEndpoint(name: "gh", url: "http://old/mcp"), MCPEndpoint(name: "own", url: "http://own/mcp")]
        server.useProxy("http://192.168.128.1:7434/", token: "proxy-token", mcp: ["shireworks", "gh"])
        XCTAssertEqual(server.settings.pushProxy, "http://192.168.128.1:7434")
        XCTAssertEqual(server.pushProxy?.token, "proxy-token")
        XCTAssertEqual(server.settings.mcpEndpoints.map(\.name), ["own", "shireworks", "gh"], "the named ones replaced, the rest kept")
        let shireworks = server.settings.mcpEndpoints.first { $0.name == "shireworks" }
        XCTAssertEqual(shireworks?.url, "http://192.168.128.1:7434/mcp/shireworks")
        XCTAssertEqual(shireworks?.headers, [MCPEndpoint.Header(name: "X-Visor-Proxy", secret: true)], "its value kept apart")
        XCTAssertEqual(VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "shireworks", header: "X-Visor-Proxy")), "proxy-token")
    }
}
