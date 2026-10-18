// The agent's questions (Claude Code's AskUserQuestion), as Visor's
// permission prompt carries them: asked by the agent's shim with the
// questions, shown to the clients as the session's pending approval, and
// answered from a client with the answers, which go back to the shim.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// An agent that does nothing: the question comes from its shim.
@MainActor
private final class QuietAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, _) = AsyncStream.makeStream() }

    /// The answers it was given, by the request they answer.
    var answered: [(String, [String: String]?)] = []

    func send(_ text: String) throws {}
    func start() throws {}
    func answer(_ request: String, with answers: [String: String]?) { answered.append((request, answers)) }
    func startsTurn(_ text: String) -> Bool { true }
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

/// What the server wrote to the shim's socket.
private final class ShimStream: ByteStream {
    var sent: [Data] = []
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() {}

    /// The envelopes in the frames sent (unmasked, as a server sends them).
    var envelopes: [Envelope] {
        sent.compactMap { data in
            let bytes = [UInt8](data)
            guard bytes.count >= 2, bytes[0] & 0x0F == 1 else { return nil }
            let length = Int(bytes[1] & 0x7F)
            let start = length == 126 ? 4 : length == 127 ? 10 : 2
            return Envelope.decode(String(decoding: bytes[start...], as: UTF8.self))
        }
    }
}

@MainActor
final class QuestionTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-question-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7984)
        server.password = "pw"
    }

    override func tearDown() async throws {
        server.stop()
    }

    func testAQuestionIsShownAndItsAnswersGoBackToTheAgent() throws {
        let record = SessionRecord(info: SessionInfo(id: "q", agent: .claude, cwd: "/tmp", title: "q", created: 0), process: QuietAgent())
        server.sessions = [record]
        // As the shim sends it: the questions as Claude Code gave them.
        let asked = #"""
            {"type":"approval_request","token":"\#(server.agentToken)","session":"q","id":"r1","text":"AskUserQuestion","prompt":"Which color?",
             "questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false}]}
            """#
        let stream = ShimStream()
        // Its socket opened, as the shim's WebSocket opens it.
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let shim = ClientConnection(stream: stream, received: Data(upgrade.utf8))
        shim.start()
        server.handle(try XCTUnwrap(Envelope.decode(asked)), from: shim)
        let pending = try XCTUnwrap(record.info.pendingApproval)
        XCTAssertEqual(pending.tool, "AskUserQuestion")
        XCTAssertEqual(pending.questions?.first?.header, "Color")
        XCTAssertEqual(pending.questions?.first?.options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(Envelope.decode(Envelope.approval(session: "q", pending).encoded())?.approval, pending, "as clients read it")

        // Answered over REST, as a client does.
        let body = Envelope.approve(session: "q", id: "r1", allow: true, answers: ["Which color?": "Blue"]).encoded()
        let reply = server.route(HTTPRequest(method: "POST", path: "/api/sessions/q/approve", headers: ["authorization": "Bearer pw"], body: body))
        XCTAssertEqual(reply.status, 200)
        XCTAssertNil(record.info.pendingApproval)
        let result = try XCTUnwrap(stream.envelopes.first { $0.type == "approval_result" })
        XCTAssertEqual(result.id, "r1")
        XCTAssertEqual(result.busy, true)
        XCTAssertEqual(result.answers, ["Which color?": "Blue"])
    }

    /// A question the agent itself asked (Codex's request_user_input) is
    /// shown the same way, and its answers go to the agent.
    func testAnAgentsOwnQuestionIsAnsweredToIt() throws {
        let agent = QuietAgent()
        let record = SessionRecord(info: SessionInfo(id: "c", agent: .codex, cwd: "/tmp", title: "c", created: 0), process: agent)
        server.sessions = [record]
        let request = ApprovalRequest(id: "codex-7", tool: "request_user_input", summary: "Which color?",
                                      questions: [AgentQuestion(question: "Which color?", options: [.init(label: "Red"), .init(label: "Blue")])])
        server.handle(.question(request), from: record)
        XCTAssertEqual(record.info.pendingApproval, request)
        let body = Envelope.approve(session: "c", id: "codex-7", allow: true, answers: ["Which color?": "Red"]).encoded()
        XCTAssertEqual(server.route(HTTPRequest(method: "POST", path: "/api/sessions/c/approve", headers: ["authorization": "Bearer pw"], body: body)).status, 200)
        XCTAssertEqual(agent.answered.first?.0, "codex-7")
        XCTAssertEqual(agent.answered.first?.1, ["Which color?": "Red"])
        XCTAssertNil(record.info.pendingApproval)
    }

    /// A tool call that is not a question carries none, as before.
    func testAPermissionCarriesNoQuestions() throws {
        let record = SessionRecord(info: SessionInfo(id: "p", agent: .claude, cwd: "/tmp", title: "p", created: 0), process: QuietAgent())
        server.sessions = [record]
        var asked = Envelope(type: "approval_request")
        asked.token = server.agentToken
        asked.session = "p"
        asked.id = "r2"
        asked.text = "Bash"
        asked.prompt = "swift test"
        server.handle(asked, from: ClientConnection(stream: ShimStream()))
        XCTAssertEqual(record.info.pendingApproval, ApprovalRequest(id: "r2", tool: "Bash", summary: "swift test"))
        XCTAssertNil(Envelope.decode(Envelope.approval(session: "p", ApprovalRequest(id: "r2", tool: "Bash", summary: "x")).encoded())?.approval?.questions)
    }
}
