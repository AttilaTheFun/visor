// Every agent's log reads into the same rows: Codex's rollout and the
// openrouter CLI's log are read as lines of Claude's shape — a list, each
// line after the last — and assembled the way Claude's are.

@testable import VisorServer
import XCTest

final class AgentLogTests: XCTestCase {
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
