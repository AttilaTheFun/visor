// Sessions in containers of their own are gone (0.50): a client that asks
// to start one, or to move a session into or out of one, is told so and
// nothing is made; a session saved while it ran in one comes back running
// on the computer; and the protocol still reads what such a session says,
// for old clients and old files.

import Foundation
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class ContainerSessionsRemovedTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-sessions-removed-" + UUID().uuidString)
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

    private func post(_ path: String, _ body: Envelope) async -> HTTPResponse {
        let request = HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer pw"], body: body.encoded())
        return await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    @Test func testStartingOneIsRefusedAndMakesNoSession() async {
        var start = Envelope(type: "start")
        start.id = "S"
        start.agent = .claude
        start.cwd = root.path
        start.container = true
        let answer = await post("/api/sessions", start)
        #expect(answer.status == 410)
        #expect((Envelope.decode(answer.body)?.message) == VisorServer.containerSessionsRemoved)
        server.perform(start, from: nil)
        #expect(server.session("S") == nil, "neither over REST nor over the socket")
    }

    @Test func testMovingOneIsRefused() async {
        let info = SessionInfo(id: "S", agent: .claude, cwd: root.path, title: "S", created: 0)
        server.sessions = [SessionRecord(info: info, process: server.makeProcess(info, resume: nil))]
        var contain = Envelope(type: "contain")
        contain.session = "S"
        contain.container = true
        let answer = await post("/api/sessions/S/contain", contain)
        #expect(answer.status == 410)
        #expect((server.session("S")?.info.container) == nil)
    }

    @Test func testOneSavedInAContainerRunsOnTheComputer() throws {
        var info = SessionInfo(id: "S", agent: .claude, cwd: root.path, title: "S", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil))
        server.sessions = [record]
        // As a server of 0.49 saved it: in a container it made.
        info.container = SessionContainer(id: "visor-s", image: "ghcr.io/attilathefun/visor:0.49.2", size: .standard)
        record.info = info
        server.saveArchiveNow()

        let again = VisorServer(port: ServerTestCase.freePort())
        again.loadSessions()
        let loaded = try #require(again.session("S"))
        #expect(loaded.info.container == nil)
        again.stop()
    }

    @Test func testTheProtocolStillReadsAContainer() throws {
        var info = SessionInfo(id: "S", agent: .codex, cwd: "/Users/someone/repo", title: "Codex", created: 0)
        info.container = SessionContainer(id: "c1", image: "visor-agent", size: .standard)
        #expect((SessionInfo(json: info.json)?.container) == info.container)
        #expect((try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).container) == info.container)
    }
}
}
