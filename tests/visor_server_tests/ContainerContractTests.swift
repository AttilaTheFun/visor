// What a server is told where it starts, and what it answers without
// credentials (docs/server-proxy.md, the server's contract): its
// environment and arguments (the arguments winning), its secrets read from
// files and passed on by their paths alone, the proxy it is given for
// pushes and MCP servers, and the health check a keep-alive asks.

import Foundation
import VisorProtocol
@testable import VisorServer
@testable import VisorServerCLI
import Testing

extension ServerTests {
@Suite @MainActor final class ContainerContractTests {
    private var server: VisorServer!
    private var folder: URL!

    init() async throws {
        TestPlatform.install()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-contract-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        VisorServer.storeRoot = folder
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    private func secret(_ name: String, _ value: String) throws -> String {
        let file = folder.appendingPathComponent(name)
        try Data((value + "\n").utf8).write(to: file)
        return file.path
    }

    @Test func testTheEnvironmentSaysWhereItIsAndTheArgumentsWin() throws {
        let password = try secret("visor-password", "hunter22")
        let token = try secret("visor-proxy", "tok-5f2a9c")
        let environment = ["VISOR_PORT": "7433", "VISOR_LISTEN": "0.0.0.0", "VISOR_PASSWORD_FILE": password,
                           "VISOR_FRONT": "http://127.0.0.1:17433,http://mac.tail:17433",
                           "VISOR_PROXY": "http://192.168.128.1:7434/", "VISOR_PROXY_TOKEN_FILE": token,
                           "VISOR_MCP": "shireworks, gh", "VISOR_UNRELATED": "x"]
        let options = try ServerOptions([], environment: environment)
        #expect(options.port == 7433)
        #expect(options.password == "hunter22", "read from its file, the line's end trimmed")
        #expect(options.proxy == "http://192.168.128.1:7434/")
        #expect(options.proxyToken == "tok-5f2a9c")
        #expect(options.mcp == ["shireworks", "gh"])
        #expect((options.settings.map { "\($0.0)=\($0.1)" }) == ["lan=on", "vpn=on", "front=http://127.0.0.1:17433,http://mac.tail:17433"])
        // A run started from this one is given the files, never the secrets.
        let passed = options.arguments.joined(separator: " ")
        #expect(!(passed.contains("hunter22") || passed.contains("tok-5f2a9c")), Comment(rawValue: passed))
        #expect(passed.contains("--password-file " + password) && passed.contains("--proxy-token-file " + token), Comment(rawValue: passed))
        #expect((try ServerOptions(options.arguments).password) == "hunter22", "the successor reads the same file")

        let given = try ServerOptions(["--port", "9000", "--listen", "loopback"], environment: environment)
        #expect(given.port == 9000, "the argument wins")
        #expect((given.settings.suffix(2).map { "\($0.0)=\($0.1)" }) == ["lan=off", "vpn=off"], "applied after the environment's")
    }

    @Test func testWhatItCanNotUseIsSaid() {
        #expect(throws: (any Error).self) { try ServerOptions([], environment: ["VISOR_PORT": "seventy"]) }
        #expect(throws: (any Error).self) { try ServerOptions([], environment: ["VISOR_LISTEN": "sometimes"]) }
        #expect(throws: (any Error).self) { try ServerOptions([], environment: ["VISOR_PASSWORD_FILE": "/nowhere/visor-password"]) }
        #expect(throws: Never.self, "an empty value is none") { try ServerOptions([], environment: ["VISOR_PORT": "  "]) }
    }

    @Test func testTheHealthCheckAnswersWithoutCredentials() throws {
        let health = server.route(HTTPRequest(method: "GET", path: "/api/health", headers: [:], body: ""))
        #expect(health.status == 200)
        let body = try #require(parseJSON(health.body))
        #expect((body["ok"].bool) == true)
        #expect((body["version"].string) != nil)
        #expect((server.route(HTTPRequest(method: "GET", path: "/api/sessions", headers: [:], body: "")).status) == 401, "nothing else without them")
        #expect((server.route(HTTPRequest(method: "POST", path: "/api/health", headers: [:], body: "")).status) != 200, "asked, not sent to")
    }

    @Test func testTheProxyGivenAtStartCarriesPushesAndTheNamedMCPServers() {
        server.settings.mcpEndpoints = [MCPEndpoint(name: "gh", url: "http://old/mcp"), MCPEndpoint(name: "own", url: "http://own/mcp")]
        server.useProxy("http://192.168.128.1:7434/", token: "proxy-token", mcp: ["shireworks", "gh"])
        #expect(server.settings.pushProxy == "http://192.168.128.1:7434")
        #expect((server.pushProxy?.token) == "proxy-token")
        #expect(server.settings.mcpEndpoints.map(\.name) == ["own", "shireworks", "gh"], "the named ones replaced, the rest kept")
        let shireworks = server.settings.mcpEndpoints.first { $0.name == "shireworks" }
        #expect((shireworks?.url) == "http://192.168.128.1:7434/mcp/shireworks")
        #expect((shireworks?.headers) == [MCPEndpoint.Header(name: "X-Visor-Proxy", secret: true)], "its value kept apart")
        #expect((VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "shireworks", header: "X-Visor-Proxy"))) == "proxy-token")
    }
}
}
