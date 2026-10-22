// Every agent's log reads into the same rows: Codex's rollout and the
// openrouter CLI's log are read as lines of Claude's shape — a list, each
// line after the last — and assembled the way Claude's are.

import ClaudeTranscript
import VisorProtocol
@testable import VisorServer
import XCTest

final class AgentLogTests: ServerTestCase {
    private func jsonl(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    func testCodexRolloutReadsAsRows() {
        let data = jsonl([
            ["type": "session_meta", "ordinal": 0, "payload": ["id": "t1"]],
            ["type": "response_item", "ordinal": 1, "payload": ["type": "message", "id": "m0", "role": "user",
                                                                 "content": [["type": "input_text", "text": "<environment_context>…"]]]],
            ["type": "response_item", "ordinal": 2, "payload": ["type": "message", "id": "m1", "role": "user",
                                                                 "content": [["type": "input_text", "text": "List the folder"]]]],
            ["type": "response_item", "ordinal": 3, "payload": ["type": "message", "id": "m2", "role": "assistant",
                                                                 "content": [["type": "output_text", "text": "Listing it."]]]],
            ["type": "event_msg", "ordinal": 4, "payload": ["type": "token_count"]],
            ["type": "response_item", "ordinal": 5, "payload": ["type": "custom_tool_call", "id": "c1", "call_id": "call1", "name": "exec",
                                                                 "input": "ls -la"]],
            ["type": "response_item", "ordinal": 6, "payload": ["type": "custom_tool_call_output", "id": "o1", "call_id": "call1",
                                                                 "output": [["type": "input_text", "text": "a.txt"]]]],
            ["type": "response_item", "ordinal": 7, "payload": ["type": "message", "id": "m3", "role": "assistant",
                                                                 "content": [["type": "output_text", "text": "One file."]]]],
        ])
        let parser = CodexRolloutParser()
        let lines = parser.lines(in: data)
        // A list: each line follows the one before.
        XCTAssertEqual(lines.map(\.parentUuid), [nil, "t1", "m0", "m1", "m2", "codex-4", "c1", "o1"])
        let rows = TranscriptAssembler.rows(in: lines.compactMap(\.record))
        // The words and the call after them are one message, as Claude's
        // are; the tool's output its own row; the next words a new message.
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(rows[0].text, "List the folder")
        XCTAssertEqual(rows[1].text, "Listing it.")
        XCTAssertEqual(rows[1].activities, ["Shell: ls -la"])
        XCTAssertEqual(rows[3].text, "One file.")
        // Rows keep the log's ids.
        XCTAssertEqual(rows[1].id, "m2")
        XCTAssertEqual(rows[3].id, "m3")

        // Reading on from the cache: the next line follows the last kept.
        let next = CodexRolloutParser()
        next.resume(after: "m3")
        let more = next.lines(in: jsonl([["type": "response_item", "ordinal": 8, "payload": ["type": "message", "id": "m4", "role": "user",
                                                                                              "content": [["type": "input_text", "text": "Thanks"]]]]]))
        XCTAssertEqual(more.first?.parentUuid, "m3")
    }

    /// The AGENTS.md files Codex read come as a user message of its own,
    /// which the user never typed: no row.
    func testCodexsAgentsInstructionsAreNoRow() {
        let data = jsonl([
            ["type": "response_item", "ordinal": 1, "payload": ["type": "message", "id": "m0", "role": "user",
                                                                 "content": [["type": "input_text",
                                                                              "text": "# AGENTS.md instructions for /root/work/r\n\n<INSTRUCTIONS>\n…"]]]],
            ["type": "response_item", "ordinal": 2, "payload": ["type": "message", "id": "m1", "role": "user",
                                                                 "content": [["type": "input_text", "text": "List the folder"]]]],
        ])
        let rows = TranscriptAssembler.rows(in: CodexRolloutParser().lines(in: data).compactMap(\.record))
        XCTAssertEqual(rows.map(\.text), ["List the folder"])
    }

    /// A restarted Codex session, read with the head it stood at (its
    /// first prompt): the second turn carries on from it, so its reply is
    /// where the conversation ends and nothing is abandoned.
    func testARestartedCodexSessionKeepsItsLaterTurns() {
        let data = jsonl([
            ["type": "response_item", "ordinal": 1, "payload": ["type": "message", "id": "p1", "role": "user",
                                                                 "content": [["type": "input_text", "text": "First"]]]],
            ["type": "response_item", "ordinal": 2, "payload": ["type": "message", "id": "r1", "role": "assistant",
                                                                 "content": [["type": "output_text", "text": "One."]]]],
            ["type": "event_msg", "ordinal": 3, "payload": ["type": "token_count"]],
            ["type": "response_item", "ordinal": 4, "payload": ["type": "message", "id": "p2", "role": "user",
                                                                 "content": [["type": "input_text", "text": "Second"]]]],
            ["type": "response_item", "ordinal": 5, "payload": ["type": "function_call_output", "id": "o2", "call_id": "c2", "output": "ok"]],
            ["type": "response_item", "ordinal": 6, "payload": ["type": "message", "id": "r2", "role": "assistant",
                                                                 "content": [["type": "output_text", "text": "Two."]]]],
            ["type": "event_msg", "ordinal": 7, "payload": ["type": "token_count"]],
        ])
        let lines = CodexRolloutParser().lines(in: data)
        XCTAssertEqual(lines.map(\.type), ["user", "assistant", "event_msg", "user", "user", "assistant", "event_msg"])
        let nodes = lines.map { ClaudeBranch.Node(uuid: $0.uuid, parentUuid: $0.parentUuid, isPrompt: $0.isPrompt, isMessage: $0.isMessage) }
        let shape = ClaudeBranch.current(nodes: nodes, head: "p1")
        XCTAssertEqual(shape.leaf, "r2")
        XCTAssertEqual(shape.abandoned, [])
        XCTAssertEqual(shape.prompts, ["p1", "p2"])
        XCTAssertFalse(shape.wentOnElsewhere)
    }

    /// Codex's folder is $CODEX_HOME when it is set (with ~ expanded), and
    /// a thread's rollout is found under it; else ~/.codex.
    func testCodexHomeHoldsTheRollouts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-codex-home-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = folder.appendingPathComponent("sessions/2026/10/20", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-10-20T10-00-00-t42.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: rollout)

        let root = SessionCatalog.codexRoot(environment: ["CODEX_HOME": folder.path])
        XCTAssertEqual(root.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(SessionCatalog.codexRollout(id: "t42", in: root)?.lastPathComponent, rollout.lastPathComponent)
        XCTAssertNil(SessionCatalog.codexRollout(id: "t43", in: root))
        XCTAssertEqual(SessionCatalog.codexRoot(environment: ["CODEX_HOME": "~/elsewhere"]).path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("elsewhere"))
        XCTAssertEqual(SessionCatalog.codexRoot(environment: [:]).path, SessionCatalog.home.appendingPathComponent(".codex").path)
    }

    func testOpenRouterLogReadsAsRows() {
        let data = jsonl([
            ["id": "u1", "message": ["role": "user", "content": "Add a README"]],
            ["id": "a1", "message": ["role": "assistant", "content": "",
                                     "tool_calls": [["id": "c1", "type": "function", "function": ["name": "bash", "arguments": "{\"command\":\"ls\"}"]]]]],
            ["id": "t1", "message": ["role": "tool", "content": "README.md", "tool_call_id": "c1"]],
            ["id": "a2", "message": ["role": "assistant", "content": "Done."]],
        ])
        let rows = TranscriptAssembler.rows(in: OpenRouterLogParser().lines(in: data).compactMap(\.record))
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(rows[1].activities, ["bash: ls"])
        XCTAssertEqual(rows.map(\.id).first, "user-file-u1")
        XCTAssertEqual(rows[3].text, "Done.")
    }
}

/// A goal's records are shown as the goal's rows: set, then met.
final class GoalRowTests: ServerTestCase {
    /// Claude Code marks the messages it writes itself (a goal set, an
    /// interruption) "<synthetic>": no model, so the session keeps showing
    /// the one that ran.
    func testASyntheticMessageNamesNoModel() {
        XCTAssertNil(ClaudeProcess.ranModel("<synthetic>"))
        XCTAssertNil(ClaudeProcess.ranModel(""))
        XCTAssertNil(ClaudeProcess.ranModel(nil))
        XCTAssertEqual(ClaudeProcess.ranModel("claude-opus-5-5"), "claude-opus-5-5")
    }

    func testGoalsBecomeTheirOwnRows() {
        let rows = TranscriptAssembler.rows(in: [
            // As Claude Code writes it: the goal's state, then the command.
            ClaudeRecord(uuid: "g2", kind: .goal(condition: "Ship it", met: false, reason: nil), timestamp: nil),
            ClaudeRecord(uuid: "g1", kind: .user(text: "/goal Ship it", images: []), timestamp: nil),
            ClaudeRecord(uuid: "g3", kind: .goal(condition: "Ship it", met: true, reason: "Shipped."), timestamp: nil),
        ])
        XCTAssertEqual(rows.map(\.role), [.user, .tool, .tool])
        XCTAssertEqual(rows.map(\.text), ["/goal Ship it", "Ship it", "Shipped."])
        XCTAssertEqual(rows.map(\.toolName), [nil, "goal", "goal-met"])
    }
}

/// What the user attached comes back from the agent's log as a list of
/// paths under the words; the row shows the words and the pictures.
final class AttachedPictureTests: ServerTestCase {
    func testAttachedPathsAreThePictures() {
        let words = TranscriptAssembler.attachments(in: "Look at this\n\nAttached image:\n- /tmp/a.png")
        XCTAssertEqual(words.text, "Look at this")
        XCTAssertEqual(words.paths, ["/tmp/a.png"])
        let only = TranscriptAssembler.attachments(in: "Attached files:\n- /tmp/a.png\n- /tmp/b.mov")
        XCTAssertEqual(only.text, "")
        XCTAssertEqual(only.paths, ["/tmp/a.png", "/tmp/b.mov"])
        // Words that merely mention it are words.
        let prose = TranscriptAssembler.attachments(in: "What does\n\nAttached image:\nmean here?")
        XCTAssertEqual(prose.text, "What does\n\nAttached image:\nmean here?")
        XCTAssertEqual(prose.paths, [])
        let rows = TranscriptAssembler.rows(in: [ClaudeRecord(uuid: "u", kind: .user(text: "See\n\nAttached image:\n- /tmp/a.png", images: []), timestamp: nil)])
        XCTAssertEqual(rows.first?.text, "See")
        XCTAssertEqual(rows.first?.images, ["/tmp/a.png"])
    }
}

/// A goal and a loop the agent keeps: one card for the goal as it is set
/// (its state and its notice), marks for the loop, and the session's
/// info following the latest of each.
@MainActor
final class GoalAndLoopTests: ServerTestCase {
    func testAGoalIsOneCardAndLoopsAreMarked() {
        let rows = TranscriptAssembler.rows(in: [
            ClaudeRecord(uuid: "g1", kind: .goal(condition: "Ship it", met: false, reason: nil), timestamp: nil),
            ClaudeRecord(uuid: "g2", kind: .goal(condition: "Ship it", met: false, reason: nil), timestamp: nil),
            ClaudeRecord(uuid: "a1", kind: .assistant(messageID: "m1", blocks: [.toolUse(id: "t1", name: "ScheduleWakeup", inputJSON: #"{"delaySeconds":600,"prompt":"x"}"#)],
                                                   stopReason: nil, model: nil, usage: nil), timestamp: "2026-09-28T10:00:00.000Z"),
            ClaudeRecord(uuid: "a2", kind: .assistant(messageID: "m2", blocks: [.toolUse(id: "t2", name: "CronCreate", inputJSON: #"{"cron":"*/5 * * * *","prompt":"x"}"#)],
                                                   stopReason: nil, model: nil, usage: nil), timestamp: nil),
        ])
        XCTAssertEqual(rows.filter { $0.toolName == "goal" }.count, 1, "the goal's notice is not a second card")
        let marks = rows.filter { $0.toolName == "loop" }.map(\.text)
        XCTAssertEqual(marks, ["wake \(Int(1_790_589_600 + 600))", "cron */5 * * * *"])
    }

    func testTheSessionFollowsTheLatestMarks() {
        let record = SessionRecord(info: SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        record.replaceEntriesForTesting([TranscriptEntry(id: "goal-file-1", role: .tool, text: "Ship it", toolName: "goal"),
                                         TranscriptEntry(id: "loop-file-1", role: .tool, text: "wake 1790000600", toolName: "loop")])
        XCTAssertEqual(record.info.goal, "Ship it")
        XCTAssertEqual(record.info.loopWake, 1_790_000_600)
        record.replaceEntriesForTesting(record.entries + [TranscriptEntry(id: "u1", role: .user, text: "/goal clear"),
                                                          TranscriptEntry(id: "loop-file-2", role: .tool, text: "stop", toolName: "loop")])
        XCTAssertNil(record.info.goal, "cleared")
        XCTAssertNil(record.info.loopWake, "stopped")
        record.replaceEntriesForTesting(record.entries + [TranscriptEntry(id: "goal-file-2", role: .tool, text: "Again", toolName: "goal"),
                                                          TranscriptEntry(id: "goal-file-3", role: .tool, text: "Done.", toolName: "goal-met")])
        XCTAssertNil(record.info.goal, "met")
    }
}
