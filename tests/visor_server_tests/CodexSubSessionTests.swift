// Codex's sub-sessions (docs/sub-sessions.md): what its app server says of
// other threads stays off the session's (a subagent's words, its turn
// ending); a side question is a turn on a throwaway copy of the thread; its
// subagents are read from the session's rollout, and each one's work from
// its own, after the copy of the conversation it started from.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// An app server played by the test: what it is sent, kept; what it says,
/// the test's lines.
@MainActor
private final class ScriptedAppServer: AgentChild {
    let output: AsyncStream<Data>
    private let speak: AsyncStream<Data>.Continuation
    let errors = AsyncStream<Data> { $0.finish() }
    let notices = AsyncStream<String> { $0.finish() }
    let exit: Task<AgentExit, Never>
    private let exited: AsyncStream<AgentExit>.Continuation
    var pid: Int32 { 1 }
    var isRunning: Bool { true }
    private(set) var written: [[String: Any]] = []

    init() {
        (output, speak) = AsyncStream.makeStream()
        let (exits, exited) = AsyncStream.makeStream(of: AgentExit.self)
        self.exited = exited
        exit = Task {
            for await exit in exits { return exit }
            return AgentExit(status: 0, signaled: false)
        }
    }

    func write(_ object: [String: Any]) { written.append(object) }
    func closeInput() {}
    func end(grace: Duration) async { exited.finish() }

    func say(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        speak.yield(data + Data("\n".utf8))
    }

    /// The last request of `method` sent, once it has been.
    func request(_ method: String) async -> [String: Any]? {
        for _ in 0..<200 {
            if let found = written.last(where: { $0["method"] as? String == method }) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@MainActor
final class CodexSubSessionTests: ServerTestCase {
    func testWhatCodexSaysIsTakenByItsThread() {
        let heard = CodexOutput.heard(#"{"method":"item/agentMessage/delta","params":{"threadId":"sub","itemId":"m1","delta":"4"}}"#)
        XCTAssertEqual(heard.map(\.thread), ["sub"])
        XCTAssertNil(CodexOutput.heard(#"{"id":3,"result":{"turn":{"id":"t1"}}}"#).first?.thread, "an answer is of no thread")
        // A subagent sent off: the call, and the session's subagents read again.
        let sent = #"{"method":"item/started","params":{"threadId":"main","item":{"type":"subAgentActivity","id":"call_1","kind":"started","agentThreadId":"sub","agentPath":"/root/arithmetic"}}}"#
        let outputs = CodexOutput.parse(sent)
        guard case .toolStarted(let id, let name, let label)? = outputs.first else { return XCTFail("no call") }
        XCTAssertEqual([id, name, label], ["call_1", "Agent", "Agent: arithmetic"])
        guard case .subagentActivity? = outputs.last else { return XCTFail("not read again") }
    }

    func testASubagentsThreadIsNotTheSessions() async throws {
        let process = CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: "main")
        let server = ScriptedAppServer()
        process.adopt(server, carried: [:])
        var events: [AgentEvent] = []
        let listening = Task { @MainActor in
            for await event in process.events {
                events.append(event)
                if case .busy(false) = event { return }
            }
        }
        server.say(["method": "turn/started", "params": ["threadId": "main", "turn": ["id": "t1"]]])
        server.say(["method": "item/agentMessage/delta", "params": ["threadId": "sub", "itemId": "m9", "delta": "4"]])
        server.say(["method": "turn/completed", "params": ["threadId": "sub", "turn": ["id": "s1", "status": "completed"]]])
        server.say(["method": "item/agentMessage/delta", "params": ["threadId": "main", "itemId": "m1", "delta": "DONE"]])
        server.say(["method": "turn/completed", "params": ["threadId": "main", "turn": ["id": "t1", "status": "completed"]]])
        await listening.value

        let said = events.compactMap { event -> String? in
            if case .delta(_, let text) = event { return text }
            return nil
        }
        XCTAssertEqual(said, ["DONE"], "the subagent's words are its own")
        let ends = events.indices.filter { if case .busy(false) = events[$0] { true } else { false } }
        let workedAt = events.firstIndex { if case .subagents = $0 { true } else { false } }
        XCTAssertEqual(ends.count, 1, "the subagent's turn ending is not the session's")
        XCTAssertNotNil(workedAt, "the session hears that its subagent worked")
        XCTAssertLessThan(try XCTUnwrap(workedAt), try XCTUnwrap(ends.first))
    }

    func testASideQuestionIsATurnOnACopyOfTheThread() async throws {
        let process = CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: "main")
        let server = ScriptedAppServer()
        process.adopt(server, carried: [:])
        let earlier = [SideQuestion(id: "q1", question: "Which file?", answer: "Sync.swift", asked: 0)]
        let asking = Task { try await process.askSide("Which word?", after: earlier) }

        let asked = await server.request("thread/fork")
        let fork = try XCTUnwrap(asked)
        let forkParams = try XCTUnwrap(fork["params"] as? [String: Any])
        XCTAssertEqual(forkParams["threadId"] as? String, "main")
        XCTAssertEqual(forkParams["ephemeral"] as? Bool, true, "never written down")
        XCTAssertEqual(forkParams["sandbox"] as? String, "read-only")
        server.say(["id": try XCTUnwrap(fork["id"] as? Int), "result": ["thread": ["id": "side"]]])

        let started = await server.request("turn/start")
        let turn = try XCTUnwrap(started)
        let turnParams = try XCTUnwrap(turn["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "side")
        let prompt = try XCTUnwrap(((turnParams["input"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(prompt.contains("Q: Which file?\nA: Sync.swift") && prompt.hasSuffix("Now: Which word?"), prompt)
        server.say(["id": try XCTUnwrap(turn["id"] as? Int), "result": ["turn": ["id": "s1"]]])
        server.say(["method": "item/completed", "params": ["threadId": "side", "item": ["type": "agentMessage", "id": "m1", "text": "PELICAN"]]])
        server.say(["method": "turn/completed", "params": ["threadId": "side", "turn": ["id": "s1", "status": "completed"]]])

        let answer = try await asking.value
        XCTAssertEqual(answer, "PELICAN")
        let unsubscribed = await server.request("thread/unsubscribe")
        let letGo = try XCTUnwrap(unsubscribed)
        XCTAssertEqual((letGo["params"] as? [String: Any])?["threadId"] as? String, "side", "its copy is let go")
    }

    func testCodexsSubagentsAreReadFromItsRollouts() {
        // As Codex 0.162 writes them: the session's rollout says each one
        // sent off and finished.
        let session = [
            #"{"type":"session_meta","payload":{"id":"main"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"main","item":{"type":"SubAgentActivity","id":"call_1","kind":"started","agent_thread_id":"sub","agent_path":"/root/arithmetic"}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"main","item":{"type":"SubAgentActivity","id":"call_2","kind":"started","agent_thread_id":"other","agent_path":"/root/docs"}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"main","item":{"type":"SubAgentActivity","id":"done-1","kind":"completed","agent_thread_id":"sub","agent_path":"/root/arithmetic"}}}"#,
        ].joined(separator: "\n")
        let listed = CodexHarness.subagents(inRollout: Data(session.utf8))
        XCTAssertEqual(listed.map(\.id), ["sub", "other"])
        XCTAssertEqual(listed.map(\.description), ["arithmetic", "docs"])
        XCTAssertEqual(listed.map(\.running), [false, true])
        XCTAssertEqual(listed.first?.call, "call_1", "the call that sent it off")
        // The words a running one is handed, through the session's agent.
        let words = CodexHarness().wordsForSubagent("Look at the tests too", to: listed[1])
        XCTAssertTrue(words.contains("/root/docs") && words.contains("send_message") && words.hasSuffix("Look at the tests too"))

        // A subagent's own rollout begins with the session's conversation.
        let own = [
            #"{"type":"session_meta","payload":{"id":"sub","parent_thread_id":"main"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Remember the word PELICAN."}]}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"sub"}}"#,
            #"{"type":"response_item","payload":{"type":"message","id":"msg_4","role":"assistant","content":[{"type":"output_text","text":"4"}]}}"#,
        ].joined(separator: "\n")
        let rows = TranscriptAssembler.rows(in: CodexRolloutParser().lines(in: CodexHarness.ownPart(of: Data(own.utf8), thread: "sub")).compactMap(\.record))
        XCTAssertEqual(rows.map(\.text), ["4"], "its own work, not the conversation it was copied from")
    }
}
