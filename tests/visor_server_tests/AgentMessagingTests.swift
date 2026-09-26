// Sessions talking to each other: an agent holding this server's token
// lists the other sessions, messages one (marked as from it, queued while
// the other works) and reads what it said. Nobody else can.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class AgentMessagingTests: XCTestCase {
    private var server: VisorServer!

    override func setUp() {
        super.setUp()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        server = VisorServer(port: 7996)
    }

    private func record(_ id: String, _ title: String, busy: Bool = false) -> SessionRecord {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.busy = busy
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                             entries: [TranscriptEntry(id: "u1", role: .user, text: "Build it"),
                                       TranscriptEntry(id: "a1", role: .assistant, text: "Built.")])
    }

    private func ask(_ mode: String, from caller: String, about target: String? = nil, text: String? = nil,
                     token: String? = nil) -> Envelope {
        var e = Envelope(type: "agent")
        e.token = token ?? server.agentToken
        e.client = caller
        e.mode = mode
        e.session = target
        e.text = text
        e.id = "r1"
        return server.agentReply(e)
    }

    func testAgentsListReadAndMessageEachOther() {
        let a = record("A", "Server work")
        let b = record("B", "Client work", busy: true)
        server.sessions = [a, b]

        let list = ask("sessions", from: "A")
        XCTAssertEqual(list.id, "r1")
        XCTAssertNil(list.error)
        XCTAssertTrue(list.text?.contains("B — Client work") == true)
        XCTAssertFalse(list.text?.contains("A — ") == true, "a session is not offered itself")

        XCTAssertEqual(ask("read", from: "A", about: "B").text, "user: Build it\n\nassistant: Built.")

        // B is working: the message waits for its turn, marked as A's.
        let sent = ask("send", from: "A", about: "B", text: "Is the API done?")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.text?.hasPrefix("Queued") == true)
        XCTAssertEqual(b.info.queued.count, 1)
        XCTAssertTrue(b.info.queued[0].contains("Visor session “Server work” (A)"))
        XCTAssertTrue(b.info.queued[0].hasSuffix("Is the API done?"))
    }

    func testOnlyThisServersAgentsAndOnlyOthers() {
        server.sessions = [record("A", "One"), record("B", "Two")]
        XCTAssertNotNil(ask("sessions", from: "A", token: "wrong").error)
        XCTAssertNotNil(ask("sessions", from: "Z").error, "an unknown caller")
        XCTAssertNotNil(ask("send", from: "A", about: "A", text: "hi").error, "not itself")
        XCTAssertNotNil(ask("send", from: "A", about: "B", text: "  ").error, "not nothing")
    }
}
