// The Runner's container servers (docs/co-tenancy.md) over a container
// backend played here: the container made with its volumes and label; the
// Visor server in it started with its password on standard input; the
// agents' sign-ins and the Runner's MCP servers given, and given again
// when they change; stopping, starting, picking up, a lost network made
// again with its volumes kept, upgrading and removing; and clients reaching
// the server through the Runner's proxy alone. The "server" is the test's
// own on this computer's loopback, the fake containers' address.

import Foundation
import VisorRunner
import XCTest

final class ContainerServersTests: XCTestCase {
    private var fake: FakeBackend!
    private var visor: FakeVisorServer!
    private var secrets: MemorySecrets!
    private var signIns: Setting<ContainerServer.SignIns>!
    private var endpoints: Setting<[MCPProxy.Endpoint]>!
    /// The server's port in its container (here, on loopback).
    private var port = 0
    /// The Runner's port for the server's clients.
    private var clientPort = 0
    private var servers: ContainerServers!

    override func setUp() async throws {
        fake = try FakeBackend()
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
        return ContainerServers(folders: fake.folder.appendingPathComponent("container-servers"), backend: fake, secrets: secrets,
                                mcpPort: 7439, endpoints: { endpoints.value }, signIns: { signIns.value },
                                clientHost: { _ in "192.0.2.7" }, patience: .seconds(20), serverPort: port)
    }

    private func spec(lan: Bool = false) -> ContainerServerSpec {
        var spec = ContainerServerSpec(id: "S1", name: "Builds", image: "ghcr.io/example/agent:1")
        spec.cpus = 2
        spec.diskBytes = 16 << 30
        spec.mounts = [.init(source: "/Users/me/Developer")]
        spec.listen = .init(port: clientPort, lan: lan, vpn: false)
        return spec
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

    func testAServerMadeHasItsContainerItsServerAndItsSignIns() throws {
        XCTAssertNil(servers.make(spec()))
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.name, "visor-server-s1")
        XCTAssertEqual(request.image, "ghcr.io/example/agent:1")
        XCTAssertEqual(request.volumes.map(\.name), ["visor-server-s1-home", "visor-server-s1-build"])
        XCTAssertEqual(request.volumes.map(\.destination), ["/root", "/var/cache/bazel"])
        XCTAssertEqual(request.volumes.last?.sizeBytes, 16 << 30)
        XCTAssertEqual(request.mounts, [.init(source: "/Users/me/Developer", destination: "/Users/me/Developer", readOnly: false)])
        XCTAssertEqual(request.labels, ["visor.container-server": "S1"])
        XCTAssertEqual(request.cpus, 2)
        // Its password given on standard input, never in a command.
        let password = try XCTUnwrap(secrets.value("container-server S1 password"))
        XCTAssertFalse(fake.calls.contains { $0.contains(password) })
        XCTAssertTrue(fake.serverCalls.contains { $0.hasPrefix("visor-server start --port \(port)") && $0.hasSuffix("--address http://192.0.2.7:\(clientPort)") })
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

    func testClientsReachTheServerThroughTheRunnersProxy() throws {
        XCTAssertNil(servers.make(spec(lan: true)))
        let password = try XCTUnwrap(secrets.value("container-server S1 password"))
        XCTAssertTrue(try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password).contains("0.45.0"))
        XCTAssertNil(servers.stop("S1"))
        XCTAssertEqual(try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password), "", "a stopped server's port is let go")
        XCTAssertNil(servers.start("S1"))
        XCTAssertTrue(try curl("http://127.0.0.1:\(clientPort)/api/hello", token: password).contains("0.45.0"))
    }

    func testSignInsAndMCPServersAreGivenAgainWhenTheyChange() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.folder.appendingPathComponent("mcp-put.json").path), "no MCP servers, none set")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.folder.appendingPathComponent("mcp-put.json").path))
    }

    func testAStoppedServerStaysStoppedUntilStarted() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertNil(servers.stop("S1"))
        XCTAssertEqual(fake.container("visor-server-s1")?.running, false)
        XCTAssertEqual(servers.state("S1")?.state, "stopped")
        XCTAssertEqual(servers.reconcile(), [:])
        servers.round()
        XCTAssertEqual(fake.container("visor-server-s1")?.running, false, "neither picking up nor asking after starts a stopped server")
        XCTAssertNil(servers.start("S1"))
        XCTAssertEqual(fake.container("visor-server-s1")?.running, true)
        XCTAssertEqual(servers.state("S1")?.state, "ready")
    }

    func testPickingUpAfterTheRunnerRestartsGivesTheServerWhatItShouldHave() throws {
        XCTAssertNil(servers.make(spec()))
        // A new Runner (its memory of what it gave gone): the same container,
        // its server still answering, given its sign-ins again.
        try FileManager.default.removeItem(at: fake.fsFile("/root/.local/share/visor/agents/claude.env"))
        servers.stopFronting()
        servers = makeServers()
        XCTAssertEqual(servers.reconcile(), [:])
        XCTAssertEqual(fake.requests.count, 1, "not made again")
        XCTAssertEqual(fake.serverCalls.filter { $0.hasPrefix("visor-server start") }.count, 1, "its server not started again")
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/claude.env"), "CLAUDE_CODE_OAUTH_TOKEN=claude-1\n")
    }

    func testAServerThatDoesntAnswerOnALostNetworkIsMadeAgainWithItsVolumes() throws {
        XCTAssertNil(servers.make(spec()))
        // Its server gone quiet, and nothing resolves in its container.
        visor.stop()
        try? FileManager.default.removeItem(at: fake.folder.appendingPathComponent("started"))
        visor = FakeVisorServer(folder: fake.folder)
        fake.networkLost = true
        servers.round()
        XCTAssertTrue(fake.calls.contains("remove visor-server-s1"), "the container alone")
        XCTAssertTrue(fake.volumes.contains("visor-server-s1-home"), "its volumes kept")
        XCTAssertEqual(fake.requests.count, 2)
        let state = try XCTUnwrap(servers.state("S1"))
        XCTAssertEqual(state.network?.ok, false)
        XCTAssertEqual(state.state, "ready")
    }

    func testUpgradingMakesItAgainWithItsVolumesAndRemovingTakesEverything() throws {
        XCTAssertNil(servers.make(spec()))
        XCTAssertNil(servers.upgrade("S1"))
        XCTAssertTrue(fake.calls.contains("remove visor-server-s1"))
        XCTAssertEqual(fake.volumes, ["visor-server-s1-home", "visor-server-s1-build"])
        XCTAssertEqual(fake.container("visor-server-s1")?.running, true)
        servers.remove("S1")
        XCTAssertNil(fake.container("visor-server-s1"))
        XCTAssertTrue(fake.volumes.isEmpty)
        XCTAssertTrue(secrets.all.isEmpty, "its password and token forgotten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: servers.folder("S1").path))
    }

    func testTheAppWritesWhatShouldBeAndTheAgentMakesItSo() throws {
        let app = ContainerServerFolders(folders: fake.folder.appendingPathComponent("container-servers"))
        XCTAssertNil(app.want(spec()))
        XCTAssertTrue(fake.requests.isEmpty, "writing makes nothing")
        XCTAssertEqual(servers.reconcile(), [:])
        XCTAssertEqual(servers.state("S1")?.state, "ready")
        let calls = fake.calls.count
        XCTAssertEqual(servers.reconcile(), [:])
        XCTAssertEqual(fake.calls.count, calls, "nothing changed, nothing done")
        var stopped = spec()
        stopped.stopped = true
        XCTAssertNil(app.want(stopped))
        servers.reconcile()
        XCTAssertEqual(fake.container("visor-server-s1")?.running, false)
        XCTAssertNil(app.wantUpgrade("S1"))
        servers.reconcile()
        XCTAssertTrue(fake.calls.contains("remove visor-server-s1"), "made again from its image")
        XCTAssertNil(app.wantRemoved("S1"))
        servers.reconcile()
        XCTAssertNil(fake.container("visor-server-s1"))
        XCTAssertTrue(fake.volumes.isEmpty)
        XCTAssertTrue(servers.servers().isEmpty)
    }

    func testWhereContainersCantBeMadeItSaysWhy() {
        fake.unavailableBecause = "This Mac can't run Linux containers"
        XCTAssertEqual(servers.make(spec()), "This Mac can't run Linux containers")
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
