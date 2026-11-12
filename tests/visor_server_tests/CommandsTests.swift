// The slash commands a session's agent takes: its own list once it has
// run, else what the same agent listed last (kept on disk), from
// `GET /api/sessions/<id>/commands`.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class CommandsTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-commands-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    private func commands(_ id: String) async -> Envelope? {
        let request = HTTPRequest(method: "GET", path: "/api/sessions/\(id)/commands", headers: ["authorization": "Bearer pw"], body: "")
        let text: String = await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0.body) } }
        return Envelope.decode(text)
    }

    @Test func testASessionOffersItsAgentsCommands() async {
        let ran = record("A")
        let fresh = record("B")
        server.sessions = [ran, fresh]
        let listed = [SlashCommand(name: "compact", description: "Summarize and clear", argumentHint: "[instructions]"),
                      SlashCommand(name: "goal", description: "Keep working until it is met")]
        _ = ran.apply(.commands(listed))
        server.keepCommands(listed, for: .claude)

        let own = await commands("A")
        #expect((own?.type) == "commands")
        #expect((own?.commands) == (listed + SubSessionCommand.offered + [VisorServer.signInCommand]), "through JSON and back, hint and all; and Visor's own: /btw, /fork, /branch and /login")
        // A session that has not run offers what its agent listed last.
        let other = await commands("B")
        #expect((other?.commands?.map(\.name)) == ["compact", "goal", "btw", "fork", "branch", "login"])
        // Kept on disk for the next launch: the agent's own.
        #expect((VisorServer.keptCommands()[.claude]) == listed)
    }
}
}
