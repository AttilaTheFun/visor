// The slash commands a session's agent takes: its own list once it has
// run, else what the same agent listed last (kept on disk), from
// `GET /api/sessions/<id>/commands`.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class CommandsTests: XCTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-commands-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7978)
        server.exposure = FakeExposure()
        server.password = "pw"
    }

    override func tearDown() async throws {
        server.stop()
        try await super.tearDown()
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

    func testASessionOffersItsAgentsCommands() async {
        let ran = record("A")
        let fresh = record("B")
        server.sessions = [ran, fresh]
        let listed = [SlashCommand(name: "compact", description: "Summarize and clear", argumentHint: "[instructions]"),
                      SlashCommand(name: "goal", description: "Keep working until it is met")]
        _ = ran.apply(.commands(listed))
        server.keepCommands(listed, for: .claude)

        let own = await commands("A")
        XCTAssertEqual(own?.type, "commands")
        XCTAssertEqual(own?.commands, listed, "through JSON and back, hint and all")
        // A session that has not run offers what its agent listed last.
        let other = await commands("B")
        XCTAssertEqual(other?.commands?.map(\.name), ["compact", "goal"])
        // Kept on disk for the next launch.
        XCTAssertEqual(VisorServer.keptCommands()[.claude], listed)
    }
}
