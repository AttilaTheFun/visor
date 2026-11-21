// A session's turn state, as the server tells it (VisorServer+Turn): each
// of the agent's events moving it — sending until the agent says it has
// the message, thinking, responding once words come, waiting from a tool
// call to its result (one that fails too), idle when the turn ends — with
// what waits taking precedence (an approval or a sign-in over a tool, a
// tool over words), the background between turns, and streamed words told
// once, never as words.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

/// What the server wrote to a client's socket.
private final class FrameStream: ByteStream {
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

    /// The turn states sent, in words of their own: "thinking", "waiting tool:Bash: ls".
    var turns: [String] {
        envelopes.filter { $0.type == "turn" }.compactMap(\.turn).map(ServerTests.TurnStateTests.said)
    }
}

extension ServerTests {
@Suite @MainActor final class TurnStateTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-turn-" + UUID().uuidString)
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
        let record = SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        server.sessions.append(record)
        return record
    }

    /// A client signed in and subscribed to `session`, and what it is sent.
    private func subscriber(to session: String) -> FrameStream {
        let stream = FrameStream()
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let client = ClientConnection(stream: stream, received: Data(upgrade.utf8))
        client.start()
        client.authenticated = true
        server.connections[ObjectIdentifier(client)] = client
        server.handle(.subscribe(session: session), from: client)
        return stream
    }

    /// A state in a few words, for comparing sequences.
    nonisolated static func said(_ turn: TurnState) -> String {
        guard turn.phase == .waiting else { return turn.phase.rawValue }
        return "waiting " + turn.waits.map { "\($0.kind.rawValue):\($0.label)" }.joined(separator: ", ")
    }

    private func now(_ record: SessionRecord) -> String { Self.said(record.currentTurn) }

    /// A turn as Claude Code's events make it: the person's message on its
    /// way, its turn begun, thinking, words, a tool and its result, more
    /// words, the end. Each change told once, as it happens.
    @Test func testATurnGoesThroughItsStatesAndEachIsToldOnce() {
        let session = record("A")
        let seen = subscriber(to: "A")
        session.sending = true
        server.handle(.busy(true), from: session)
        server.handle(.activity("Thinking…"), from: session)
        #expect(now(session) == "sending", "the agent doesn't have it yet")
        server.handle(.turnBegan, from: session)
        #expect(now(session) == "thinking", "it has it, and has said nothing yet")
        server.handle(.thinking(true), from: session)
        server.handle(.thinking(false), from: session)
        for piece in ["Let ", "me ", "look."] { server.handle(.delta(message: "M", text: piece), from: session) }
        #expect(now(session) == "responding")
        server.handle(.toolStarted(id: "t1", name: "Bash", label: "Bash: bazel test //tests:linux", tasks: nil), from: session)
        #expect(now(session) == "waiting tool:Bash: bazel test //tests:linux")
        server.handle(.toolFinished(id: "t1"), from: session)
        server.handle(.thinking(true), from: session)
        #expect(now(session) == "thinking")
        server.handle(.thinking(false), from: session)
        server.handle(.delta(message: "N", text: "Done."), from: session)
        server.handle(.busy(false), from: session)
        #expect(now(session) == "idle")
        #expect(seen.turns == ["sending", "thinking", "responding", "waiting tool:Bash: bazel test //tests:linux", "thinking",
                               "responding", "idle"], "each change once: \(seen.turns)")
        // The subscribe's own state says where it stood then, and no
        // streamed words go out at all.
        #expect(seen.envelopes.first { $0.type == "ephemeral" }?.turn == .idle)
        #expect(!seen.envelopes.contains { $0.type == "delta" }, "no words told")
        #expect(session.info.turn == nil, "idle is none in the list")
    }

    /// The list carries the state while it isn't idle, for the line under
    /// the session's row.
    @Test func testTheListCarriesTheTurnWhileItIsNotIdle() {
        let session = record("A")
        server.handle(.busy(true), from: session)
        server.handle(.toolStarted(id: "a1", name: "Agent", label: "Waiting: Review the diff", tasks: nil), from: session)
        server.handle(.toolStarted(id: "a2", name: "Task", label: "Waiting: Check the copy", tasks: nil), from: session)
        #expect(session.info.turn == TurnState(.waiting, waits: [TurnWait(kind: .subagent, id: "a1", label: "Review the diff", work: .subagent),
                                                                 TurnWait(kind: .subagent, id: "a2", label: "Check the copy", work: .subagent)]))
        #expect(SessionInfo(json: session.info.json)?.turn == session.info.turn)
        server.handle(.toolFinished(id: "a1"), from: session)
        #expect(now(session) == "waiting subagent:Check the copy")
        server.handle(.busy(false), from: session)
        #expect(session.info.turn == nil)
    }

    /// A tool whose call fails ends as one that works: its result (an
    /// error) comes as a `tool_result`, and the agent takes it up.
    @Test func testAToolThatErrorsEndsItsWait() {
        let failed = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1",\
            "is_error":true,"content":"Exit code 1\\nerror: no such target"}]}}
            """
        #expect(ClaudeOutput.parse(failed) == [.toolResults(["toolu_1"])])
        let session = record("A")
        server.handle(.busy(true), from: session)
        server.handle(.toolStarted(id: "toolu_1", name: "Bash", label: "Bash: bazel test //nope", tasks: nil), from: session)
        #expect(now(session) == "waiting tool:Bash: bazel test //nope")
        // What ClaudeProcess makes of the result: the call finished, and
        // the model thinks again.
        server.handle(.toolFinished(id: "toolu_1"), from: session)
        server.handle(.thinking(true), from: session)
        #expect(now(session) == "thinking")
        // A turn cut short in a tool (interrupted, the agent gone) ends
        // the wait with the turn.
        server.handle(.toolStarted(id: "toolu_2", name: "Bash", label: "Bash: sleep 600", tasks: nil), from: session)
        server.handle(.busy(false), from: session)
        #expect(now(session) == "idle")
    }

    /// When several things are true: an approval or a sign-in over a tool,
    /// a tool over words, words over thinking, thinking over sending, and
    /// the background only between turns.
    @Test func testPrecedence() {
        let session = record("A")
        session.sending = true
        server.handle(.busy(true), from: session)
        server.handle(.toolStarted(id: "t1", name: "Bash", label: "Bash: rm -rf build", tasks: nil), from: session)
        #expect(now(session) == "waiting tool:Bash: rm -rf build", "a tool call says the agent has the message")
        session.setPendingApproval(ApprovalRequest(id: "p1", tool: "Bash", summary: "rm -rf build"))
        #expect(now(session) == "waiting approval:rm -rf build", "an approval over the tool it is for")
        session.setPendingApproval(ApprovalRequest(id: "q1", tool: "AskUserQuestion", summary: "Which way?",
                                                   questions: [AgentQuestion(question: "Which way?", header: "Way", options: [], multiSelect: false)]))
        #expect(now(session) == "waiting question:Which way?")
        session.setPendingApproval(nil)
        server.handle(.toolFinished(id: "t1"), from: session)
        server.handle(.delta(message: "M", text: "Removed."), from: session)
        // Words while a parallel call still runs: the call.
        server.handle(.toolStarted(id: "t2", name: "Read", label: "Read: README.md", tasks: nil), from: session)
        server.handle(.delta(message: "M", text: " More"), from: session)
        #expect(now(session) == "waiting tool:Read: README.md")
        server.handle(.toolFinished(id: "t2"), from: session)
        #expect(now(session) == "thinking", "the result ends the words before it")
        // Thinking and the task list are no waits.
        server.handle(.toolStarted(id: "todo", name: "TodoWrite", label: "Tasks", tasks: [TaskItem(title: "Fix it", state: .active)]), from: session)
        server.handle(.thinking(true), from: session)
        #expect(now(session) == "thinking")
        // The background between turns, not during one.
        server.handle(.background([StatusItem(id: "b1", kind: .monitor, label: "CI checks on PR #92", running: true),
                                   StatusItem(id: "b2", kind: .subagent, label: "Review the diff", running: true)]), from: session)
        #expect(now(session) == "thinking")
        server.handle(.busy(false), from: session)
        #expect(now(session) == "waiting background:CI checks on PR #92, subagent:Review the diff")
        server.handle(.background([]), from: session)
        #expect(now(session) == "idle")
    }

    /// The pure precedence, every level against the one below it.
    @Test func testThePrecedenceLadder() {
        let tool = StatusItem(id: "t", kind: .shell, label: "Bash: ls", running: true)
        let done = StatusItem(id: "d", kind: .shell, label: "Bash: pwd", running: false)
        let away = StatusItem(id: "b", kind: .monitor, label: "CI", running: true)
        let approval = ApprovalRequest(id: "p", tool: "Bash", summary: "ls")
        func of(approval: ApprovalRequest? = nil, signIn: Bool = false, busy: Bool = true, sending: Bool = false,
                responding: Bool = false, status: [StatusItem] = [], background: [StatusItem] = []) -> String {
            Self.said(TurnState.of(approval: approval, signIn: signIn, busy: busy, sending: sending, responding: responding,
                                   status: status, background: background))
        }
        #expect(of(approval: approval, signIn: true, responding: true, status: [tool]) == "waiting approval:ls, signIn:Claude")
        #expect(of(signIn: true, status: [tool]) == "waiting signIn:Claude")
        #expect(of(responding: true, status: [tool, done]) == "waiting tool:Bash: ls")
        #expect(of(sending: true, responding: true, status: [done]) == "responding")
        #expect(of(sending: true) == "sending")
        #expect(of() == "thinking")
        #expect(of(busy: false, sending: true, background: [away]) == "sending")
        #expect(of(busy: false, background: [away]) == "waiting background:CI")
        #expect(of(busy: true, background: [away]) == "thinking")
        #expect(of(busy: false) == "idle")
    }

    /// Streamed words after the first cost nothing: no state to tell.
    @Test func testWordsAfterTheFirstDoNothing() {
        let session = record("A")
        let seen = subscriber(to: "A")
        server.handle(.busy(true), from: session)
        let told = seen.envelopes.count
        server.handle(.delta(message: "M", text: "One"), from: session)
        let afterFirst = seen.envelopes.count
        for piece in (0..<50).map({ " \($0)" }) { server.handle(.delta(message: "M", text: piece), from: session) }
        #expect(afterFirst == told + 1, "the first word tells `responding`")
        #expect(seen.envelopes.count == afterFirst, "the rest tell nothing")
    }

    /// Claude Code says each turn's beginning with its `system/init`, a
    /// subagent's work by its parent call, and what runs in the background
    /// whole: those are what the states come from. What it runs in the
    /// background but no longer waits on isn't said apart from what it
    /// waits on: every task it lists wakes it when it ends.
    @Test func testWhatClaudeCodeSays() {
        let begun = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-4","permissionMode":"auto"}"#
        #expect(ClaudeOutput.parse(begun) == [.began(session: "s1", model: "claude-opus-4", keySource: nil, mode: "auto")])
        let sub = #"{"type":"stream_event","parent_tool_use_id":"toolu_agent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}"#
        #expect(ClaudeOutput.parse(sub) == [.subagentWork(toolUseID: "toolu_agent")], "a subagent's words are not the reply's")
        let started = #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_1","name":"Bash"}}}"#
        #expect(ClaudeOutput.parse(started) == [.blockStarted(thinking: false)], "a tool's block ends the words before it")
    }
}
}
