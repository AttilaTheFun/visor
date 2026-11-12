// Permission prompts by where an agent runs (Logan, 11 Nov): on the
// computer itself a session chooses auto-approving (Claude Code's own auto
// mode, Codex in its sandbox — never a bypass) or manual, and a client may
// switch it; in a container a session always skips them (bypassing, Codex
// with full access), whatever a client asks.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class PermissionsTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-permissions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7997)
    }

    private func host(inContainer: Bool) {
        ServerPlatform.current.host = HostDetails(name: inContainer ? "primary" : "Mac", system: inContainer ? "linux" : "macos",
                                                  inContainer: inContainer, dataDirectory: FileManager.default.temporaryDirectory)
    }

    private func start(_ id: String, skip: Bool?, agent: AgentKind = .claude) -> SessionRecord? {
        var start = Envelope(type: "start")
        start.id = id
        start.agent = agent
        start.cwd = "/tmp"
        start.skipPermissions = skip
        server.perform(start, from: nil)
        return server.session(id)
    }

    private func ask(_ id: String, skip: Bool) {
        var permissions = Envelope(type: "permissions")
        permissions.session = id
        permissions.skipPermissions = skip
        server.perform(permissions, from: nil)
    }

    @Test func testOnTheComputerItselfTheSessionChoosesAutoOrManual() throws {
        host(inContainer: false)
        let auto = try #require(start("a", skip: true))
        #expect(auto.info.skipPermissions, "auto-approving, as chosen")
        let manual = try #require(start("m", skip: false))
        #expect(!manual.info.skipPermissions)
        ask("m", skip: true)
        #expect(manual.info.skipPermissions, "a client switches it")
        ask("a", skip: false)
        #expect(!auto.info.skipPermissions)
    }

    @Test func testInAContainerPromptsAreAlwaysSkipped() throws {
        host(inContainer: true)
        let asked = try #require(start("c", skip: false))
        #expect(asked.info.skipPermissions)
        #expect(asked.process.skipPermissions)
        ask("c", skip: false)
        #expect(asked.info.skipPermissions, "a client's ask for manual refused")
    }

    @Test func testCodexHasFullAccessOnlyInAContainer() {
        host(inContainer: false)
        let native = CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil)
        #expect((native.threadParams()["sandbox"] as? String) == "workspace-write", "its own sandbox, auto-approving or not")
        host(inContainer: true)
        let contained = CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil)
        #expect((contained.threadParams()["sandbox"] as? String) == "danger-full-access")
    }
}
}
