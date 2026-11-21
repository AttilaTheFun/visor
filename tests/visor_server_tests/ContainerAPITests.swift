// The Sessions container over REST (VisorServer+Container): `GET
// /api/container` and `POST /api/container/start|stop|restart`, each an admin's,
// answered by the engine the binary gave (a fake here), or "off" where
// there's none; and turning the container on giving agent-proxy a free
// relay port where it has none, never Shireworks' 7499.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class ContainerAPITests {
    final class FakeEngine: SessionsContainer {
        let calls = Mutex<[String]>([])
        let told = Mutex<[ServerSettings]>([])
        let taken: Set<Int>

        init(taken: Set<Int> = []) { self.taken = taken }

        func status() async -> ContainerStatus {
            calls.withLock { $0.append("status") }
            return ContainerStatus(state: .stopped, enabled: true, canRun: true, cpus: 8, memoryGiB: 12, idleMinutes: 30, relayPort: 7438)
        }

        func start() async -> ContainerStatus {
            calls.withLock { $0.append("start") }
            return ContainerStatus(state: .noEgress, enabled: true, canRun: true, egress: "relay-client check ended 1",
                                   errors: ["no egress"])
        }

        func stop() async -> ContainerStatus {
            calls.withLock { $0.append("stop") }
            return ContainerStatus(state: .stopped, enabled: true, canRun: true)
        }

        func restart() async -> ContainerStatus {
            calls.withLock { $0.append("restart") }
            return ContainerStatus(state: .running, enabled: true, canRun: true)
        }

        var sharedFolders: [String] { ["/Volumes/Sessions"] }

        func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun {
            throw CancellationError()
        }

        func settingsChanged(_ settings: ServerSettings) { told.withLock { $0.append(settings) } }

        func loopbackPortIsFree(_ port: Int) -> Bool { !taken.contains(port) }
    }

    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-api-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ path: String, bearer: String? = "pw") async -> HTTPResponse {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        let request = HTTPRequest(method: method, path: path, headers: headers, body: "", trusted: false)
        return await withCheckedContinuation { done in
            server.route(request) { done.resume(returning: $0) }
        }
    }

    private func status(_ response: HTTPResponse) -> ContainerStatus? {
        parseJSON(response.body).flatMap(ContainerStatus.init(json:))
    }

    @Test func withoutAnEngineItsOffAndSaysWhy() async throws {
        let read = try #require(status(await call("GET", "/api/container")))
        #expect(read.state == .off && !read.canRun)
        #expect(read.errors == [VisorServer.noContainerEngine])
        #expect(status(await call("POST", "/api/container/start"))?.state == .off)
    }

    @Test func itsAnAdminsCall() async throws {
        server.sessionsContainer = FakeEngine()
        #expect(await call("GET", "/api/container", bearer: nil).status == 401)
        #expect(await call("POST", "/api/container/start", bearer: "wrong").status == 401)
    }

    @Test func theEngineAnswersStatusStartStopAndRestart() async throws {
        let engine = FakeEngine()
        server.sessionsContainer = engine
        let read = try #require(status(await call("GET", "/api/container")))
        #expect(read.state == .stopped && read.cpus == 8 && read.memoryGiB == 12 && read.relayPort == 7438)
        let started = try #require(status(await call("POST", "/api/container/start")))
        #expect(started.state == .noEgress && started.egress == "relay-client check ended 1" && started.errors == ["no egress"])
        #expect(status(await call("POST", "/api/container/stop"))?.state == .stopped)
        #expect(status(await call("POST", "/api/container/restart"))?.state == .running)
        #expect(engine.calls.withLock { $0 } == ["status", "start", "stop", "restart"])
        #expect(await call("GET", "/api/container/start").status == 404)
        #expect(await call("POST", "/api/container/reboot").status == 404)
    }

    @Test func turningItOnGivesAgentProxyARelayPort() async throws {
        let engine = FakeEngine()
        server.sessionsContainer = engine
        #expect(server.settings.agentProxy?.relayPort == nil, "off: none given")
        #expect(server.apply(ServerControlsChange(containerEnabled: true)) == nil)
        #expect(server.settings.container?.enabled == true)
        #expect(server.settings.agentProxy?.relayPort == RelayPortChoice.preferred)
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).agentProxy?.relayPort == RelayPortChoice.preferred, "kept")
        #expect(engine.told.withLock { $0.last?.agentProxy?.relayPort } == RelayPortChoice.preferred, "the engine told")
        // Off and on again: the port stays as it was.
        _ = server.apply(ServerControlsChange(containerEnabled: false))
        _ = server.apply(ServerControlsChange(containerEnabled: true))
        #expect(server.settings.agentProxy?.relayPort == RelayPortChoice.preferred)
    }

    @Test func aPortSetAlreadyIsKept() async throws {
        var proxy = AgentProxySettings()
        proxy.relayPort = 7471
        server.settings.agentProxy = proxy
        server.sessionsContainer = FakeEngine()
        _ = server.apply(ServerControlsChange(containerEnabled: true))
        #expect(server.settings.agentProxy?.relayPort == 7471)
    }

    @Test func aTakenPortIsPassedOverAndShireworksNeverTaken() async throws {
        server.sessionsContainer = FakeEngine(taken: Set([7438] + Array(7440...7498)))
        var proxy = AgentProxySettings()
        proxy.mcp = AgentProxySettings.MCP()
        server.settings.agentProxy = proxy
        _ = server.apply(ServerControlsChange(containerEnabled: true))
        #expect(server.settings.agentProxy?.relayPort == 7500, "7499 is Shireworks'")
        #expect(server.settings.agentProxy?.mcp?.port == 7439, "the rest of agent-proxy's as it was")
    }

    @Test func theChoiceAvoidsVisorsPortsAndShireworks() {
        #expect(RelayPortChoice.choose { _ in true } == 7438)
        #expect(RelayPortChoice.choose { $0 != 7438 } == 7440)
        #expect(RelayPortChoice.choose { $0 == 7499 || $0 == 7433 || $0 == 7439 } == nil)
        #expect(RelayPortChoice.choose(alsoAvoided: [7438]) { _ in true } == 7440, "the MCP pass-through's, moved there")
    }
}
}
