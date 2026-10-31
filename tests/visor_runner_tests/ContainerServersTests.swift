// The Runner's container servers (docs/co-tenancy.md) over a script that
// plays Apple's `container`: the container made with its volumes, its
// server's port published and its label; the Visor server in it started
// with its password on standard input; the agents' sign-ins and the
// Runner's MCP servers given, and given again when they change; stopping,
// starting, picking up, a lost network made again with its volumes kept,
// and removing; its port published on loopback alone, and clients reaching
// it only through the Runner's proxy. The "server" is the test's own on this
// computer's loopback, at the port it is published to.

import Foundation
import VisorRunner
import XCTest

final class ContainerServersTests: XCTestCase {
    private var fake: FakeContainer!
    private var visor: FakeVisorServer!
    private var secrets: MemorySecrets!
    private var signIns: Setting<ContainerServer.SignIns>!
    private var endpoints: Setting<[MCPProxy.Endpoint]>!
    /// The server's port, where it is published on loopback.
    private var port = 0
    /// The Runner's port for the server's clients.
    private var clientPort = 0
    private var servers: ContainerServers!

    override func setUp() async throws {
        fake = try FakeContainer()
        visor = FakeVisorServer(folder: fake.folder)
        secrets = MemorySecrets()
        signIns = Setting(ContainerServer.SignIns(claudeToken: "claude-1", openrouterKey: nil, codexAuth: Data("{\"codex\":1}".utf8)))
        endpoints = Setting([])
        port = freePort()
        clientPort = port + 1
        servers = makeServers()
    }

    override func tearDown() async throws {
        servers.stopFronting()
        visor.stop()
        try? FileManager.default.removeItem(at: fake.folder)
    }

    private func makeServers() -> ContainerServers {
        let signIns = signIns!, endpoints = endpoints!
        // The server listens at the port it is published to: here, both are loopback's.
        return ContainerServers(folders: fake.folder.appendingPathComponent("container-servers"), cli: fake.cli, secrets: secrets,
                                mcpPort: 7439, endpoints: { endpoints.value }, signIns: { signIns.value },
                                clientHost: { _ in "192.0.2.7" }, patience: .seconds(20), serverPort: port)
    }

    private func spec(lan: Bool = false) -> ContainerServerSpec {
        var spec = ContainerServerSpec(id: "S1", name: "Builds", image: "ghcr.io/example/agent:1")
        spec.cpus = 2
        spec.diskBytes = 16 << 30
        spec.mounts = [.init(source: "/Users/me/Developer")]
        spec.listen = .init(port: clientPort, lan: lan, vpn: false)
        spec.loopbackPort = port
        return spec
    }

    func testAServerMadeHasItsContainerItsServerAndItsSignIns() throws {
        XCTAssertNil(servers.make(spec()))
        let run = try XCTUnwrap(fake.calls.first { $0.hasPrefix("run ") })
        XCTAssertTrue(run.contains("--name visor-server-s1"))
        XCTAssertTrue(run.contains("--volume visor-server-s1-home:/root"))
        XCTAssertTrue(run.contains("--volume visor-server-s1-build:/var/cache/bazel"))
        XCTAssertTrue(run.contains("--mount type=bind,source=/Users/me/Developer,target=/Users/me/Developer"))
        XCTAssertTrue(run.contains("--label visor.container-server=S1"))
        XCTAssertTrue(run.contains("--publish 127.0.0.1:\(port):\(port)"), "on loopback alone")
        XCTAssertTrue(run.hasSuffix("ghcr.io/example/agent:1 sleep infinity"))
        XCTAssertTrue(fake.has("volume-visor-server-s1-build"))
        // Its password given on standard input, never on `container`'s command line.
        let password = try XCTUnwrap(secrets.value("container-server S1 password"))
        XCTAssertFalse(fake.calls.contains { !$0.hasPrefix("visor-server ") && $0.contains(password) })
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("visor-server start --port \(port)") && $0.hasSuffix("--address http://192.0.2.7:\(clientPort)") })
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/claude.env"), "CLAUDE_CODE_OAUTH_TOKEN=claude-1\n")
        XCTAssertNil(fake.written("/root/.local/share/visor/agents/openrouter.env"))
        XCTAssertEqual(fake.written("/root/.codex/auth.json"), "{\"codex\":1}")
        let state = try XCTUnwrap(servers.state("S1"))
        XCTAssertEqual(state.state, "ready")
        XCTAssertEqual(state.server?.version, "0.45.0")
        XCTAssertEqual(state.code, "visor-code")
        XCTAssertEqual(state.address, "http://192.0.2.7:\(clientPort)")
        XCTAssertEqual(servers.servers().map(\.name), ["Builds"])
        let mode = try FileManager.default.attributesOfItem(atPath: servers.folder("S1").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700, "its folder is this user's alone")
    }

    func testClientsReachTheServerOnlyThroughTheRunnersProxy() throws {
        XCTAssertNil(servers.make(spec(lan: true)))
        let run = try XCTUnwrap(fake.calls.first { $0.hasPrefix("run ") })
        XCTAssertTrue(run.contains("--publish 127.0.0.1:\(port):\(port)"), "on loopback alone, though the LAN reaches it")
        let password = try XCTUnwrap(secrets.value("container-server S1 password"))
        let hello = try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password)
        XCTAssertTrue(hello.contains("0.45.0"), "through the Runner's proxy: \(hello)")
        XCTAssertNil(servers.stop("S1"))
        XCTAssertEqual(try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password), "", "a stopped server's port is let go")
        XCTAssertNil(servers.start("S1"))
        XCTAssertTrue(try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password).contains("0.45.0"))
    }

    /// What `curl` gets of `url` with the bearer `token` (empty when nothing answers).
    private func curl(_ url: String, token: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-m", "5", "-H", "Authorization: Bearer \(token)", url]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testSignInsAndMCPServersAreGivenAgainWhenTheyChange() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertFalse(fake.has("mcp-put.json"), "no MCP servers, none set")
        signIns.value.claudeToken = "claude-2"
        signIns.value.openrouterKey = "or-1"
        endpoints.value = [MCPProxy.Endpoint(name: "gh", url: "http://127.0.0.1:7450/mcp", headers: ["X-Visor-Session": "$SESSION_ID"],
                                             secretHeaders: ["Authorization"])]
        servers.round()
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/claude.env"), "CLAUDE_CODE_OAUTH_TOKEN=claude-2\n")
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/openrouter.env"), "OPENROUTER_API_KEY=or-1\n")
        let put = try XCTUnwrap(try? Data(contentsOf: fake.folder.appendingPathComponent("mcp-put.json")))
        let listed = try XCTUnwrap((try JSONSerialization.jsonObject(with: put) as? [String: Any])?["endpoints"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["url"] as? String, "http://192.168.64.1:7439/mcp/gh", "the Runner's proxy, at the container's gateway")
        let headers = try XCTUnwrap(listed.first?["headers"] as? [[String: Any]])
        XCTAssertTrue(headers.contains { $0["name"] as? String == "X-Visor-Session" && $0["value"] as? String == "$SESSION_ID" })
        let token = try XCTUnwrap(secrets.value("container-server S1 mcpToken"))
        XCTAssertTrue(headers.contains { $0["name"] as? String == MCPProxy.tokenHeader && $0["value"] as? String == token && $0["secret"] as? Bool == true })
        XCTAssertFalse(headers.contains { $0["name"] as? String == "Authorization" }, "a secret header never enters the server")
        XCTAssertTrue(servers.admits(token))
        XCTAssertFalse(servers.admits("someone else's"))
        // Nothing changed: nothing written again.
        try FileManager.default.removeItem(at: fake.folder.appendingPathComponent("mcp-put.json"))
        servers.round()
        XCTAssertFalse(fake.has("mcp-put.json"))
    }

    func testAStoppedServerStaysStoppedUntilStarted() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertNil(servers.stop("S1"))
        XCTAssertTrue(fake.has("stopped-visor-server-s1"))
        XCTAssertEqual(servers.state("S1")?.state, "stopped")
        XCTAssertEqual(servers.pickUp(), [:])
        servers.round()
        XCTAssertTrue(fake.has("stopped-visor-server-s1"), "neither picking up nor asking after starts a stopped server")
        XCTAssertNil(servers.start("S1"))
        XCTAssertTrue(fake.has("running-visor-server-s1"))
        XCTAssertEqual(servers.state("S1")?.state, "ready")
    }

    func testPickingUpAfterTheRunnerRestartsGivesTheServerWhatItShouldHave() throws {
        XCTAssertNil(servers.make(spec()))
        let runs = fake.calls.filter { $0.hasPrefix("run ") }.count
        // A new Runner (its memory of what it gave gone): the same container,
        // its server still answering, given its sign-ins again.
        try FileManager.default.removeItem(at: fake.folder.appendingPathComponent("fs/_root_.local_share_visor_agents_claude.env"))
        servers.stopFronting()
        servers = makeServers()
        XCTAssertEqual(servers.pickUp(), [:])
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run ") }.count, runs, "not made again")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("visor-server start") }.count, 1, "its server not started again")
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/claude.env"), "CLAUDE_CODE_OAUTH_TOKEN=claude-1\n")
    }

    func testAServerThatDoesntAnswerOnALostNetworkIsMadeAgainWithItsVolumes() throws {
        XCTAssertNil(servers.make(spec()))
        // Its server gone quiet, and nothing resolves in its container.
        visor.stop()
        fake.remove("started")
        visor = FakeVisorServer(folder: fake.folder)
        fake.touch("nonetwork")
        servers.round()
        XCTAssertTrue(fake.calls.contains("delete --force visor-server-s1"))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("volume delete") }, "its volumes kept")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run ") }.count, 2)
        let state = try XCTUnwrap(servers.state("S1"))
        XCTAssertEqual(state.network?.ok, false)
        XCTAssertEqual(state.state, "ready")
    }

    func testUpgradingMakesItAgainWithItsVolumesAndRemovingTakesEverything() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertNil(servers.upgrade("S1"))
        XCTAssertTrue(fake.calls.contains("delete --force visor-server-s1"))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("volume delete") })
        XCTAssertTrue(fake.has("running-visor-server-s1"))
        servers.remove("S1")
        XCTAssertFalse(fake.has("running-visor-server-s1"))
        XCTAssertFalse(fake.has("volume-visor-server-s1-home"))
        XCTAssertFalse(fake.has("volume-visor-server-s1-build"))
        XCTAssertTrue(secrets.all.isEmpty, "its password and token forgotten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: servers.folder("S1").path))
    }

    func testWithoutApplesContainerItSaysSo() {
        let servers = ContainerServers(folders: fake.folder.appendingPathComponent("container-servers"),
                                       cli: ContainerCLI(tool: "/no/such/container"), secrets: secrets, mcpPort: 7439,
                                       endpoints: { [] }, signIns: { .init() })
        XCTAssertEqual(servers.make(spec()), "Apple's container is not installed (github.com/apple/container)")
        XCTAssertEqual(servers.state("S1")?.state, "failed")
    }

    func testTheSpecReadsWithDefaults() throws {
        let folder = fake.folder.appendingPathComponent("spec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id": "abc", "image": "i", "listen": {"port": 7444}}"#.utf8).write(to: folder.appendingPathComponent("server.json"))
        let spec = try ContainerServerSpec.read(folder)
        XCTAssertEqual(spec.name, "abc")
        XCTAssertEqual(spec.listen, .init(port: 7444))
        XCTAssertFalse(spec.stopped)
        XCTAssertEqual(spec.containerName, "visor-server-abc")
    }
}
