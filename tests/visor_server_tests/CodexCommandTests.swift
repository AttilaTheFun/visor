// Codex's own slash commands: its app-server takes /goal, /compact and
// /review as requests, not as words of a turn. Typed in a Codex session,
// they are read as such; the goal Codex reports is the session's; a goal
// the user changed reads back from the rollout as the command they typed;
// and the composer offers them before Codex has run.

import ClaudeTranscript
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class CodexCommandTests: ServerTestCase {
    func testAGoalWrittenBackItsOwnWayIsTheOneSent() {
        let sent = "/goal Ok yes please migrate the existing stuff to Bazel first, and get it working\n\nI understand it will be limited"
        // Codex's rollout keeps the breaks and quotes escaped, and may cut it short.
        XCTAssertTrue(CommandWords.same("/goal Ok yes please migrate the existing stuff to Bazel first, and get it working\\n\\nI under", sent))
        XCTAssertTrue(SessionRecord.sameWords("/goal Ok yes please migrate the existing stuff to Bazel first, and get it", sent))
        XCTAssertFalse(CommandWords.same("/goal something else entirely", sent))
        XCTAssertFalse(CommandWords.same("/compact", "/goal compact"))
        XCTAssertFalse(CommandWords.same("plain words", "plain words "), "only commands are matched loosely")
    }

    func testTheGoalTheAgentSaysIsNotUndoneByTheRows() {
        let info = SessionInfo(id: "C", agent: .codex, cwd: "/tmp", title: "Codex", created: 0)
        let record = SessionRecord(info: info, process: CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                                   entries: [TranscriptEntry(id: "u1", role: .user, text: "/goal clear"),
                                             TranscriptEntry(id: "u2", role: .user, text: "/goal ship 0.31")])
        record.noteMarks(lookingBack: false)
        XCTAssertEqual(record.info.goal, "ship 0.31", "the latest /goal row sets the goal")
        _ = record.apply(.goal("ship 0.31 and test it", met: false))
        record.entries.append(TranscriptEntry(id: "a1", role: .assistant, text: "Working on it."))
        record.noteMarks(lookingBack: false)
        XCTAssertEqual(record.info.goal, "ship 0.31 and test it", "Codex's own word stands")
    }

    func testTheCommandsAreRead() {
        XCTAssertEqual(CodexCommand("/goal"), .showGoal)
        XCTAssertEqual(CodexCommand(" /goal  ship the release \n"), .setGoal("ship the release"))
        XCTAssertEqual(CodexCommand("/goal clear"), .clearGoal)
        XCTAssertEqual(CodexCommand("/goal pause"), .pauseGoal)
        XCTAssertEqual(CodexCommand("/goal resume"), .resumeGoal)
        XCTAssertEqual(CodexCommand("/goal fix the\nflaky test"), .setGoal("fix the\nflaky test"))
        XCTAssertEqual(CodexCommand("/compact"), .compact)
        XCTAssertEqual(CodexCommand("/review"), .review(nil))
        XCTAssertEqual(CodexCommand("/review the sync code"), .review("the sync code"))
        // Anything else goes to the agent as typed.
        XCTAssertNil(CodexCommand("/goals are good"))
        XCTAssertNil(CodexCommand("/prompts:deploy"))
        XCTAssertNil(CodexCommand("set a goal"))
    }

    /// Codex's question to the user (request_user_input), as the app server
    /// sends it: each question with the id its answer goes back under.
    func testCodexsQuestionIsRead() {
        let line = #"{"id":7,"method":"item/tool/requestUserInput","params":{"threadId":"t","turnId":"u","itemId":"call_1","questions":[{"id":"preferred_color","header":"Color","question":"Which color do you prefer?","isOther":true,"isSecret":false,"options":[{"label":"Red","description":"Choose Red."},{"label":"Blue","description":"Choose Blue."}]}],"isBlocking":false,"autoResolutionMs":null}}"#
        guard case .questions(let id, let asked)? = CodexOutput.parse(line).first else { return XCTFail("not a question") }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(asked.map(\.id), ["preferred_color"])
        XCTAssertEqual(asked.first?.question, AgentQuestion(question: "Which color do you prefer?", header: "Color",
                                                            options: [.init(label: "Red", description: "Choose Red."),
                                                                      .init(label: "Blue", description: "Choose Blue.")]))
        XCTAssertTrue(CodexAppServerProcess.questionArguments.contains("features.default_mode_request_user_input=true"))
    }

    func testWhatTheAppServerSaysOfTurnsAndGoals() {
        let goal = #"{"threadId":"t","objective":"Ship it","status":"active","tokenBudget":null,"tokensUsed":10,"timeUsedSeconds":125,"createdAt":1,"updatedAt":2}"#
        XCTAssertEqual(lastGoal(#"{"method":"thread/goal/updated","params":{"threadId":"t","turnId":null,"goal":\#(goal)}}"#),
                       .some(CodexGoal(objective: "Ship it", status: "active", tokensUsed: 10, timeUsedSeconds: 125)))
        XCTAssertEqual(lastGoal(#"{"method":"thread/goal/cleared","params":{"threadId":"t"}}"#), .some(nil))
        // The answer to a goal's request carries it; null is none.
        XCTAssertEqual(lastGoal(#"{"id":4,"result":{"goal":null}}"#), .some(nil))
        XCTAssertEqual(lastGoal(#"{"id":4,"result":{"goal":\#(goal)}}"#)??.objective, "Ship it")
        XCTAssertEqual(lastGoal(#"{"id":5,"result":{"turn":{"id":"u1"}}}"#), .none, "other answers say nothing of it")
        // A turn Codex started itself.
        guard case .turnStarted(let id)? = CodexOutput.parse(#"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"u2"}}}"#).first else {
            return XCTFail("no turn")
        }
        XCTAssertEqual(id, "u2")
        XCTAssertEqual(CodexGoal(objective: "Ship it", status: "paused", timeUsedSeconds: 125).summary,
                       "Goal: Ship it — paused (/goal resume), 2 min so far.")
    }

    private func lastGoal(_ line: String) -> CodexGoal?? {
        for output in CodexOutput.parse(line).reversed() {
            if case .goal(let goal) = output { return .some(goal) }
        }
        return .none
    }

    func testTheSessionTakesTheGoalCodexReports() {
        let record = SessionRecord(info: SessionInfo(id: "C", agent: .codex, cwd: "/tmp", title: "Codex", created: 0),
                                   process: CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        _ = record.apply(.goal("Ship it", met: false))
        XCTAssertEqual(record.info.goal, "Ship it")
        XCTAssertFalse(record.goalWasMet("Ship it"))
        _ = record.apply(.goal(nil, met: true))
        XCTAssertNil(record.info.goal)
        XCTAssertTrue(record.goalWasMet("Ship it"), "met, as Codex said: the push says achieved")
        _ = record.apply(.goal("Next", met: false))
        _ = record.apply(.goal(nil, met: false))
        XCTAssertFalse(record.goalWasMet("Next"), "cleared, not met")
        // A command answered in words is a notice.
        let envelope = record.apply(.notice("No goal is set."))
        XCTAssertEqual(record.notice, "No goal is set.")
        XCTAssertEqual(envelope?.notice, "No goal is set.")
    }

    func testAGoalTheUserChangedReadsBackAsTheirCommand() {
        func said(_ text: String) -> String? {
            CodexRolloutParser.goalCommand("<codex_internal_context source=\"user_goal\">\n" + text + "\n</codex_internal_context>")
        }
        XCTAssertEqual(said("User set the goal: \"Ship it\"\nUser set goal status: \"active\"."), "/goal Ship it")
        XCTAssertEqual(said("User set the goal: \"Fix the \"flaky\"\ntest\"\nUser set goal status: \"active\"."), "/goal Fix the \"flaky\"\ntest")
        XCTAssertEqual(said("User set goal status: \"paused\"."), "/goal pause")
        XCTAssertEqual(said("User set goal status: \"active\"."), "/goal resume")
        XCTAssertEqual(said("User cleared the goal."), "/goal clear")
        XCTAssertNil(CodexRolloutParser.goalCommand("<codex_internal_context source=\"goal\">\nContinue working toward the active thread goal."))

        // In the rollout: the user's row, where the context is not one.
        let line: [String: Any] = ["type": "response_item", "ordinal": 1,
                                   "payload": ["type": "message", "id": "g1", "role": "user", "content": [[
                                       "type": "input_text",
                                       "text": "<codex_internal_context source=\"user_goal\">\nUser set the goal: \"Ship it\"\nUser set goal status: \"active\".\n</codex_internal_context>"]]]]
        let data = Data(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self).utf8)
        let rows = TranscriptAssembler.rows(in: CodexRolloutParser().lines(in: data).compactMap(\.record))
        XCTAssertEqual(rows.map(\.text), ["/goal Ship it"])
        XCTAssertEqual(rows.first?.role, .user)
    }

    /// Codex 0.156 writes a goal the user set only as an event (no "User
    /// set the goal" context); 0.162 writes both. Either way, one row: the
    /// user's command.
    func testAGoalLoggedOnlyAsAnEventReadsBackOnce() {
        func rows(_ lines: [[String: Any]]) -> [TranscriptEntry] {
            let data = Data(lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
                .joined(separator: "\n").utf8)
            return TranscriptAssembler.rows(in: CodexRolloutParser().lines(in: data).compactMap(\.record))
        }
        func event(_ objective: String, _ status: String, at time: String) -> [String: Any] {
            ["timestamp": time, "type": "event_msg",
             "payload": ["type": "thread_goal_updated", "threadId": "T",
                         "goal": ["threadId": "T", "objective": objective, "status": status, "tokensUsed": "0"]]]
        }
        func context(_ text: String, id: String) -> [String: Any] {
            ["type": "response_item",
             "payload": ["type": "message", "id": id, "role": "user", "content": [["type": "input_text", "text": text]]]]
        }
        let continuation = context("<codex_internal_context source=\"goal\">\nContinue working toward the active thread goal.\n<objective>\nShip it\n</objective>", id: "c1")

        // 0.156: the event alone, then Codex's own continuation context.
        let old = rows([event("Ship it", "active", at: "2026-10-15T00:02:48.370Z"), continuation,
                        event("Ship it", "paused", at: "2026-10-15T00:10:00.000Z"),
                        event("Ship it", "active", at: "2026-10-15T00:11:00.000Z"),
                        event("Ship it", "complete", at: "2026-10-15T00:20:00.000Z"),
                        event("Then this", "active", at: "2026-10-15T00:30:00.000Z"),
                        ["timestamp": "2026-10-15T00:40:00.000Z", "type": "event_msg", "payload": ["type": "thread_goal_cleared", "threadId": "T"]]])
        XCTAssertEqual(old.map(\.text), ["/goal Ship it", "/goal pause", "/goal resume", "/goal Then this", "/goal clear"])
        XCTAssertTrue(old.allSatisfy { $0.role == .user })

        // 0.162: the context, then the same goal as an event: one row.
        let new = rows([context("<codex_internal_context source=\"user_goal\">\nUser set the goal: \"Ship it\"\nUser set goal status: \"active\".\n</codex_internal_context>", id: "g1"),
                        event("Ship it", "active", at: "2026-10-15T00:02:48.370Z"), continuation])
        XCTAssertEqual(new.map(\.text), ["/goal Ship it"])
    }

    func testTheComposerOffersThemBeforeCodexHasRun() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-codex-commands-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7984)
        defer { server.stop() }
        let record = SessionRecord(info: SessionInfo(id: "C", agent: .codex, cwd: "/tmp", title: "Codex", created: 0),
                                   process: CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        XCTAssertEqual(server.commands(for: record).map(\.name), ["goal", "compact", "review"])
    }
}
