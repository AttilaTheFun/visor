// Claude Code's stream JSON, read as what it means: the session, words,
// tool calls begun and finished, and a turn's end; anything else nothing.

import AgentWrapper
import XCTest

final class ClaudeLineTests: XCTestCase {
    func testTheLinesItKnows() {
        XCTAssertEqual(ClaudeLine.read(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus"}"#),
                       [.started(sessionID: "s1", model: "claude-opus")])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"assistant","message":{"id":"m","content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"Hi"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}"#),
                       [.thinking, .text(id: "m-1", text: "Hi"), .toolStarted(id: "t1", name: "Bash", label: "Bash: ls -la")])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}"#),
                       [.toolFinished(id: "t1")])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"result","subtype":"success","is_error":false,"result":"Hi"}"#), [.turnEnded(error: nil)])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#), [.turnEnded(error: "error_max_turns")])
    }

    func testAnythingElseIsNothing() {
        XCTAssertEqual(ClaudeLine.read("not json"), [])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"stream_event"}"#), [])
        XCTAssertEqual(ClaudeLine.read(#"{"type":"system","subtype":"compact_boundary"}"#), [])
    }

    func testAUserTurnIsOneLineOfStreamJSON() throws {
        let line = ClaudeLine.userTurn("Hello\nthere")
        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        XCTAssertEqual((object["message"] as? [String: Any])?["content"] as? String, "Hello\nthere")
    }
}
