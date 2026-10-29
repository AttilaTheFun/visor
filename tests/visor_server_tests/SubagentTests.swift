// A session's subagents (docs/sub-sessions.md): read from the agent's own
// files, listed while they run and after, if seen running here, until the
// person closes each; the person's words for one go to the session's agent
// to pass on, and a finished one goes on as a session of its own.

import ClaudeTranscript
import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

/// An agent that writes down what it is sent.
@MainActor
private final class ListeningAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    let resumeID: String?
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var said: [String] = []

    init(resume: String? = "claude-p") {
        resumeID = resume
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { said.append(text) }
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

/// A harness whose agent's subagents are set by the test.
private final class SubagentHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"
    let listed = Mutex<[SubagentInfo]>([])

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: [], defaultModel: "opus") }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}
    func subagents(id: String, cwd: String) -> [SubagentInfo] { listed.withLock { $0 } }
    func subagentTranscript(id: String, cwd: String, subagent: String) -> [TranscriptEntry] {
        [TranscriptEntry(id: "s1", role: .assistant, text: "Looked at \(subagent).")]
    }
    func continueSubagent(id: String, cwd: String, subagent: String) -> String? { "claude-\(subagent)" }

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { ListeningAgent(resume: resume) }
}

@MainActor
final class SubagentTests: ServerTestCase {
    func testASessionsSubagentsAreReadFromBesideItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-subagents-" + UUID().uuidString)
        let folder = root.appendingPathComponent("S/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"agentType":"Explore","description":"Map the plumbing","toolUseId":"toolu_1","finished":true}"#.utf8)
            .write(to: folder.appendingPathComponent("agent-a1.meta.json"))
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":true,"agentId":"a1","message":{"role":"user","content":"Map it"}}"#,
            #"{"type":"assistant","uuid":"m1","parentUuid":"u1","isSidechain":true,"agentId":"a1","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Mapped."}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("agent-a1.jsonl"))
        let agents = ClaudeSubagent.all(of: root.appendingPathComponent("S.jsonl"))
        XCTAssertEqual(agents.map(\.id), ["a1"])
        XCTAssertEqual(agents.first?.description, "Map the plumbing")
        XCTAssertEqual(agents.first?.toolUseID, "toolu_1")
        XCTAssertEqual(agents.first?.finished, true)
        // Its own file is all sidechain: read as its conversation, not skipped.
        let records = ClaudeTranscriptParser.lines(contentsOf: try XCTUnwrap(agents.first).transcript, sidechain: true).compactMap(\.record)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(ClaudeTranscriptParser.lines(contentsOf: try XCTUnwrap(agents.first).transcript).isEmpty, "a session's file skips them")
    }

    func testAFinishedSubagentsConversationIsWrittenAsASessionOfItsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-subagent-session-" + UUID().uuidString)
        let folder = root.appendingPathComponent("S/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"agentType":"Explore","description":"Map the plumbing","finished":true}"#.utf8)
            .write(to: folder.appendingPathComponent("agent-a1.meta.json"))
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":true,"agentId":"a1","sessionId":"S","cwd":"/tmp/a/b","message":{"role":"user","content":"Map it"}}"#,
            #"{"type":"api-request","sessionId":"S","agentId":"a1"}"#,
            #"{"type":"assistant","uuid":"m1","parentUuid":"u1","isSidechain":true,"agentId":"a1","sessionId":"S","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Mapped."}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("agent-a1.jsonl"))
        let agent = try XCTUnwrap(ClaudeSubagent.all(of: root.appendingPathComponent("S.jsonl")).first)

        let file = try XCTUnwrap(agent.session("N", beside: root.appendingPathComponent("S.jsonl")))
        XCTAssertEqual(file, root.appendingPathComponent("N.jsonl"), "beside the session that sent it off")
        let written = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertEqual(written.map { $0["uuid"] as? String }, ["u1", "m1"], "its conversation, without what was sent for it")
        for record in written {
            XCTAssertEqual(record["sessionId"] as? String, "N")
            XCTAssertEqual(record["isSidechain"] as? Bool, false)
            XCTAssertNil(record["agentId"])
        }
        XCTAssertEqual(written.first?["cwd"] as? String, "/tmp/a/b", "paths kept as they were")
        // A session's file now, read as one rather than skipped.
        XCTAssertEqual(ClaudeTranscriptParser.lines(contentsOf: file).compactMap(\.record).count, 2)
    }

    func testAFinishedSubagentGoesOnAsASessionOfItsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-subagent-continue-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7993)
        defer { server.stop() }
        let harness = SubagentHarness()
        server.harnesses = AgentHarnesses([harness])
        var info = SessionInfo(id: "P", agent: .claude, cwd: "/tmp", title: "Parser", created: 0)
        info.model = "sonnet"
        let parent = SessionRecord(info: info, process: ListeningAgent())
        server.sessions = [parent]
        harness.listed.withLock { $0 = [SubagentInfo(id: "a1", description: "Map the plumbing", type: "Explore", running: true)] }
        server.refreshSubagents(of: parent)

        // While it works, it is reached through the session's agent only.
        server.perform(.fork(id: "C", parent: "P", origin: .subagent, text: "Go on", subagent: "a1"), from: nil)
        XCTAssertNil(server.session("C"))

        harness.listed.withLock { $0[0].running = false }
        server.refreshSubagents(of: parent)
        server.perform(.fork(id: "C", parent: "P", origin: .subagent, text: "Now the tests", subagent: "a1"), from: nil)
        let session = try XCTUnwrap(server.session("C"))
        XCTAssertEqual(session.info.parent, "P")
        XCTAssertEqual(session.info.origin, .subagent)
        XCTAssertEqual(session.info.title, "Map the plumbing")
        XCTAssertEqual([session.info.cwd, session.info.model], ["/tmp", "sonnet"])
        XCTAssertEqual(session.entries.map(\.text), ["Looked at a1."], "the subagent's conversation")
        let agent = try XCTUnwrap(session.process as? ListeningAgent)
        XCTAssertEqual(agent.resumeID, "claude-a1", "resumed from the copy of the subagent's conversation")
        XCTAssertEqual(agent.said, ["Now the tests"])
        XCTAssertNil(session.pendingFork, "its own conversation already")
        // Its row under the session stands for the subagent's now.
        XCTAssertTrue(parent.info.subagents.isEmpty)
        XCTAssertEqual(parent.stored.closedSubagents, ["a1"])
        XCTAssertEqual((parent.process as? ListeningAgent)?.said, [], "the parent is not told")
    }

    func testASubagentsMessagesAreNotTheThreads() {
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"model":"claude-opus-5-5","usage":{"input_tokens":900000},"content":[{"type":"tool_use","id":"t9","name":"Read","input":{}}]}}"#
        XCTAssertEqual(ClaudeOutput.parse(line), [.subagentWork(toolUseID: "toolu_1")], "no tool row, no context count of the session's")
        let own = #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[]}}"#
        XCTAssertNotEqual(ClaudeOutput.parse(own), [.subagentWork(toolUseID: "")])
    }

    func testTheSessionWaitingOnASubagentSaysSo() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"Add two numbers","prompt":"What is 2 + 2?","subagent_type":"general-purpose"}}]}}"#
        guard case .assistant(_, _, let tools)? = ClaudeOutput.parse(line).first else { return XCTFail("no assistant message") }
        XCTAssertEqual(tools.map(\.label), ["Waiting: Add two numbers"])
        XCTAssertEqual(ClaudeOutput.label(name: "Read", input: ["file_path": "/tmp/a"]).hasPrefix("Read: "), true)
    }

    func testSubagentsSeenRunningAreListedUntilClosed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-subagent-list-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7992)
        defer { server.stop() }
        let harness = SubagentHarness()
        server.harnesses = AgentHarnesses([harness])
        let agent = ListeningAgent()
        let record = SessionRecord(info: SessionInfo(id: "P", agent: .claude, cwd: "/tmp", title: "P", created: 0), process: agent)
        server.sessions = [record]

        // A long session's past subagents are not listed: none was seen running.
        harness.listed.withLock { $0 = [SubagentInfo(id: "old", description: "Long ago", type: "Explore", running: false)] }
        server.refreshSubagents(of: record)
        XCTAssertTrue(record.info.subagents.isEmpty)

        // One sent off now is, and stays once it has finished.
        harness.listed.withLock { $0.append(SubagentInfo(id: "a1", description: "Map the plumbing", type: "Explore", running: true)) }
        server.refreshSubagents(of: record)
        XCTAssertEqual(record.info.subagents.map(\.id), ["a1"])

        // The person's words for it go to the session's agent, to pass on.
        server.perform(.toSubagent(session: "P", id: "a1", text: "Look at the tests too"), from: nil)
        XCTAssertEqual(agent.said.count, 1)
        XCTAssertTrue(agent.said[0].contains("agent id a1") && agent.said[0].hasSuffix("Look at the tests too"))
        XCTAssertEqual(server.subagentTranscript(of: record, agent: "a1").map(\.text), ["Looked at a1."])

        harness.listed.withLock { $0[1].running = false }
        server.refreshSubagents(of: record)
        XCTAssertEqual(record.info.subagents.map(\.running), [false], "finished, still listed")
        server.perform(.toSubagent(session: "P", id: "a1", text: "Anything else?"), from: nil)
        XCTAssertEqual(agent.said.count, 1, "a finished subagent is no longer reached through the session's agent")

        // One that finished before it was first read, but whose call was
        // seen starting, is listed all the same.
        server.handle(.toolStarted(id: "toolu_quick", name: "Agent", label: "Waiting: Quick", tasks: nil), from: record)
        harness.listed.withLock { $0.append(SubagentInfo(id: "q1", description: "Quick", type: "Explore", running: false, call: "toolu_quick")) }
        server.refreshSubagents(of: record)
        XCTAssertEqual(record.info.subagents.map(\.id), ["a1", "q1"])

        server.perform(.closeSubagent(session: "P", id: "a1"), from: nil)
        XCTAssertEqual(record.info.subagents.map(\.id), ["q1"])
        server.refreshSubagents(of: record)
        XCTAssertEqual(record.info.subagents.map(\.id), ["q1"], "closed stays closed")
        XCTAssertEqual(record.stored.closedSubagents, ["a1"])
    }
}
