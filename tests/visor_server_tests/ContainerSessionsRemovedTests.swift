// Sessions in containers of their own are gone (0.50): a client that asks
// to start one, or to move a session into or out of one, is told so and
// nothing is made; a session saved while it ran in one comes back running
// on the computer; and the protocol still reads what such a session says,
// for old clients and old files.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class ContainerSessionsRemovedTests: ServerTestCase {
    private var server: VisorServer!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-sessions-removed-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: Self.freePort())
        server.password = "pw"
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func post(_ path: String, _ body: Envelope) async -> HTTPResponse {
        let request = HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer pw"], body: body.encoded())
        return await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    func testStartingOneIsRefusedAndMakesNoSession() async {
        var start = Envelope(type: "start")
        start.id = "S"
        start.agent = .claude
        start.cwd = root.path
        start.container = true
        let answer = await post("/api/sessions", start)
        XCTAssertEqual(answer.status, 410)
        XCTAssertEqual(Envelope.decode(answer.body)?.message, VisorServer.containerSessionsRemoved)
        server.perform(start, from: nil)
        XCTAssertNil(server.session("S"), "neither over REST nor over the socket")
    }

    func testMovingOneIsRefused() async {
        let info = SessionInfo(id: "S", agent: .claude, cwd: root.path, title: "S", created: 0)
        server.sessions = [SessionRecord(info: info, process: server.makeProcess(info, resume: nil))]
        var contain = Envelope(type: "contain")
        contain.session = "S"
        contain.container = true
        let answer = await post("/api/sessions/S/contain", contain)
        XCTAssertEqual(answer.status, 410)
        XCTAssertNil(server.session("S")?.info.container)
    }

    func testOneSavedInAContainerRunsOnTheComputer() throws {
        var info = SessionInfo(id: "S", agent: .claude, cwd: root.path, title: "S", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil))
        server.sessions = [record]
        // As a server of 0.49 saved it: in a container it made.
        info.container = SessionContainer(id: "visor-s", image: "ghcr.io/attilathefun/visor:0.49.2", size: .standard)
        record.info = info
        server.saveArchiveNow()

        let again = VisorServer(port: Self.freePort())
        again.loadSessions()
        let loaded = try XCTUnwrap(again.session("S"))
        XCTAssertNil(loaded.info.container)
        again.stop()
    }

    func testTheProtocolStillReadsAContainer() throws {
        var info = SessionInfo(id: "S", agent: .codex, cwd: "/Users/someone/repo", title: "Codex", created: 0)
        info.container = SessionContainer(id: "c1", image: "visor-agent", size: .standard)
        XCTAssertEqual(SessionInfo(json: info.json)?.container, info.container)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).container, info.container)
    }
}
