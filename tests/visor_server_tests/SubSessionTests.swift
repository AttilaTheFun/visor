// Sub-sessions (docs/sub-sessions.md): a fork or branch is a session of
// its own, made from its parent's conversation by the parent's agent's
// own id, and copied by its agent as it starts; a side question is
// answered on the parent's `side` without going into its conversation.

import ClaudeTranscript
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// An agent that writes down what is asked of it.
@MainActor
private final class SubAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String?
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var said: [String] = []
    /// Where it was told to fork from: nil inside for a fork of the whole.
    var forkedAt: String??
    var asked: [(question: String, earlier: [String])] = []
    var answer: Result<String, AgentProcessError> = .success("The parser.")

    init(resume: String?) {
        resumeID = resume
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { said.append(text) }
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
    func fork(at message: String?) -> Bool {
        forkedAt = .some(message)
        return true
    }

    func askSide(_ question: String, after earlier: [SideQuestion]) async throws -> String {
        asked.append((question, earlier.map(\.question)))
        return try answer.get()
    }
}

private final class SubHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: [], defaultModel: "opus") }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}
    func forkPoint(row: String, id: String, cwd: String) -> String? { row == "nowhere" ? nil : "end-of-" + row }

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { SubAgent(resume: resume) }
}

@MainActor
final class SubSessionTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-sub-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7991)
        server.harnesses = AgentHarnesses([SubHarness()])
    }

    override func tearDown() async throws {
        server.stop()
    }

    /// A parent whose agent's own conversation is "claude-p", with three rows.
    private func parent() -> SessionRecord {
        let info = SessionInfo(id: "P", agent: .claude, cwd: "/tmp", title: "Parser", skipPermissions: false,
                               model: "sonnet", effort: "high", created: 0)
        let rows = [TranscriptEntry(id: "u1", role: .user, text: "Fix the parser"),
                    TranscriptEntry(id: "a1", role: .assistant, text: "Fixed."),
                    TranscriptEntry(id: "u2", role: .user, text: "Now the lexer")]
        let record = SessionRecord(info: info, process: SubAgent(resume: "claude-p"), entries: rows)
        server.sessions = [record]
        return record
    }

    func testTheWireCarriesParentOriginAndSideQuestions() throws {
        var info = SessionInfo(id: "F", agent: .claude, cwd: "/tmp", title: "Fork of Parser", created: 1)
        info.parent = "P"
        info.origin = .branch
        info.side = [SideQuestion(id: "s1", question: "Which file?", answer: "Lexer.swift", asked: 2),
                     SideQuestion(id: "s2", question: "Why?", failure: "Claude stopped before it answered.", asked: 3)]
        XCTAssertEqual(SessionInfo(json: info.json), info)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)), info)

        let fork = Envelope.fork(id: "F", parent: "P", origin: .branch, at: "a1", text: "Try again")
        let read = try XCTUnwrap(Envelope.decode(fork.encoded()))
        XCTAssertEqual(read.type, "fork")
        XCTAssertEqual([read.id, read.parent, read.at, read.text], ["F", "P", "a1", "Try again"])
        XCTAssertEqual(read.origin, .branch)
        let side = try XCTUnwrap(Envelope.decode(Envelope.side(session: "P", id: "s1", question: "Which file?").encoded()))
        XCTAssertEqual([side.type, side.session, side.id, side.text], ["side", "P", "s1", "Which file?"])
    }

    func testTheCommandsAreReadAsTyped() {
        XCTAssertEqual(SubSessionCommand(" /btw  which file holds it? "), .side("which file holds it?"))
        XCTAssertEqual(SubSessionCommand("/btw"), .side(nil))
        XCTAssertEqual(SubSessionCommand("/fork try the other layout"), .fork("try the other layout"))
        XCTAssertEqual(SubSessionCommand("/branch"), .branch(nil))
        XCTAssertNil(SubSessionCommand("/btwx what"))
        XCTAssertNil(SubSessionCommand("fork it"))
    }

    func testClaudesAnswerToAControlRequestIsRead() {
        let success = #"{"type":"control_response","response":{"subtype":"success","request_id":"side-3","response":{"response":"PELICAN.","synthetic":false}}}"#
        XCTAssertEqual(ClaudeOutput.parse(success), [.controlResponse(id: "side-3", answer: "PELICAN.", error: nil)])
        let failure = #"{"type":"control_response","response":{"subtype":"error","request_id":"side-4","error":"side_question timed out"}}"#
        XCTAssertEqual(ClaudeOutput.parse(failure), [.controlResponse(id: "side-4", answer: nil, error: "side_question timed out")])
    }

    func testAForkIsASessionOfItsOwnMadeFromItsParentsConversation() throws {
        let parent = parent()
        server.perform(.fork(id: "F", parent: "P", origin: .fork, text: "Try the other layout"), from: nil)
        let fork = try XCTUnwrap(server.session("F"))
        XCTAssertEqual(fork.info.parent, "P")
        XCTAssertEqual(fork.info.origin, .fork)
        XCTAssertEqual(fork.info.title, "Fork of Parser")
        XCTAssertEqual([fork.info.cwd, fork.info.model, fork.info.effort], ["/tmp", "sonnet", "high"])
        XCTAssertFalse(fork.info.skipPermissions, "the parent's permissions")
        XCTAssertEqual(fork.entries.map(\.id), parent.entries.map(\.id), "the parent's conversation, whole")
        let agent = try XCTUnwrap(fork.process as? SubAgent)
        XCTAssertEqual(agent.resumeID, "claude-p", "made from the parent's own conversation")
        XCTAssertEqual(agent.forkedAt, .some(nil), "a copy of the whole")
        XCTAssertEqual(fork.pendingFork, PendingFork(from: "claude-p", at: nil))
        XCTAssertEqual(agent.said, ["Try the other layout"], "started on its prompt")
        XCTAssertEqual((parent.process as? SubAgent)?.said, [], "the parent is not told")
    }

    func testABranchGoesOnFromAPointAndWaitsForThePerson() throws {
        _ = parent()
        server.perform(.fork(id: "B", parent: "P", origin: .branch, at: "a1"), from: nil)
        let branch = try XCTUnwrap(server.session("B"))
        XCTAssertEqual(branch.info.title, "Branch of Parser")
        XCTAssertEqual(branch.entries.map(\.id), ["u1", "a1"], "through the turn it goes on from")
        let agent = try XCTUnwrap(branch.process as? SubAgent)
        XCTAssertEqual(agent.forkedAt, .some("end-of-a1"), "at the end of that turn, in the agent's own terms")
        XCTAssertEqual(agent.said, [], "idle until the person says something")
    }

    func testAForkIsMadeOnceItsCopyHasAnIdOfItsOwn() throws {
        _ = parent()
        server.perform(.fork(id: "F", parent: "P", origin: .fork), from: nil)
        let fork = try XCTUnwrap(server.session("F"))
        fork.followFile()
        XCTAssertNil(fork.followed, "the parent's file is the parent's")
        fork.forkMade(as: "claude-p")
        XCTAssertNotNil(fork.pendingFork, "the parent's own id is no copy")
        fork.forkMade(as: "claude-f")
        XCTAssertNil(fork.pendingFork)
        XCTAssertNil(fork.stored.fork)

        // An agent made again for a fork not yet copied makes the copy.
        server.perform(.fork(id: "G", parent: "P", origin: .branch, at: "u1"), from: nil)
        let branch = try XCTUnwrap(server.session("G"))
        XCTAssertEqual(branch.stored.fork, PendingFork(from: "claude-p", at: "end-of-u1"), "kept across a restart")
        XCTAssertEqual(branch.entries.map(\.id), ["u1", "a1"], "a prompt's turn is its answer too")
        server.rebuild(branch)
        XCTAssertEqual((branch.process as? SubAgent)?.forkedAt, .some("end-of-u1"))

        // A row the agent cannot place is no branch.
        server.perform(.fork(id: "H", parent: "P", origin: .branch, at: "nowhere"), from: nil)
        XCTAssertNil(server.session("H"))
    }

    func testABranchAtARowGoesOnFromTheEndOfItsTurn() {
        let records = [
            ClaudeRecord(uuid: "r1", kind: .user(text: "Fix it", images: []), timestamp: nil),
            ClaudeRecord(uuid: "r2", kind: .assistant(messageID: "msg_a", blocks: [], stopReason: nil, model: nil, usage: nil), timestamp: nil),
            ClaudeRecord(uuid: "r3", kind: .assistant(messageID: "msg_a", blocks: [], stopReason: "tool_use", model: nil, usage: nil), timestamp: nil),
            ClaudeRecord(uuid: "r4", kind: .toolResult(toolUseID: "t1", text: "ok", images: [], isError: false), timestamp: nil),
            ClaudeRecord(uuid: "r5", kind: .assistant(messageID: "msg_b", blocks: [], stopReason: "end_turn", model: nil, usage: nil), timestamp: nil),
            ClaudeRecord(uuid: "r6", kind: .user(text: "Now the lexer", images: []), timestamp: nil),
            ClaudeRecord(uuid: "r7", kind: .assistant(messageID: "msg_c", blocks: [], stopReason: "end_turn", model: nil, usage: nil), timestamp: nil),
        ]
        XCTAssertEqual(ClaudeForkPoint.point(row: "msg_a", in: records), "r5", "a reply with tool calls: through their results, to the turn's end")
        XCTAssertEqual(ClaudeForkPoint.point(row: "msg_a#1", in: records), "r5")
        XCTAssertEqual(ClaudeForkPoint.point(row: "user-file-r1", in: records), "r5", "a prompt: through its answer")
        XCTAssertEqual(ClaudeForkPoint.point(row: "msg_c", in: records), "r7")
        XCTAssertNil(ClaudeForkPoint.point(row: "sending-abc", in: records), "a row not in the file yet")
    }

    func testNothingToForkBeforeTheConversationBegins() {
        let record = SessionRecord(info: SessionInfo(id: "N", agent: .claude, cwd: "/tmp", title: "New", created: 0),
                                   process: SubAgent(resume: nil))
        server.sessions = [record]
        server.perform(.fork(id: "F", parent: "N", origin: .fork), from: nil)
        XCTAssertNil(server.session("F"))
    }

    func testASideQuestionIsAnsweredBesideTheConversation() async throws {
        let parent = parent()
        let agent = try XCTUnwrap(parent.process as? SubAgent)
        server.perform(.side(session: "P", id: "s1", question: "Which file holds it?"), from: nil)
        XCTAssertEqual(parent.info.side.map(\.question), ["Which file holds it?"])
        XCTAssertNil(parent.info.side.first?.answer, "thought over")
        try await until { parent.info.side.first?.answer != nil }
        XCTAssertEqual(parent.info.side.first?.answer, "The parser.")
        XCTAssertEqual(parent.entries.count, 3, "nothing goes into the conversation")
        XCTAssertEqual(agent.said, [])

        // The next is asked with the ones before it, and a failure is said.
        agent.answer = .failure(.declined("Claude stopped before it answered."))
        server.deliver("/btw And why?", to: parent)
        try await until { parent.info.side.count == 2 && parent.info.side[1].failure != nil }
        XCTAssertEqual(agent.asked.last?.earlier, ["Which file holds it?"])
        XCTAssertEqual(parent.info.side[1].failure, "Claude stopped before it answered.")

        server.perform(.endSide(session: "P"), from: nil)
        XCTAssertTrue(parent.info.side.isEmpty)
    }

    func testTheMenuOffersVisorsOwnInPlaceOfTheAgents() {
        let record = parent()
        record.commands = [SlashCommand(name: "btw", description: "Claude's own", argumentHint: ""),
                           SlashCommand(name: "compact", description: "Compact", argumentHint: "")]
        let names = server.commands(for: record).map(\.name)
        XCTAssertEqual(names.filter { $0 == "btw" }.count, 1)
        XCTAssertTrue(["compact", "btw", "fork", "branch"].allSatisfy(names.contains))
        XCTAssertEqual(server.commands(for: record).first { $0.name == "btw" }?.description, SubSessionCommand.offered[0].description)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let limit = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < limit else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
