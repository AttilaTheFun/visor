import Foundation

/// A stand-in for `claude -p` in stream JSON: it says its session, then
/// answers each turn with "echo: <words>" and ends the turn. Written to a
/// temporary file as a Python script.
enum FakeClaude {
    static let script = #"""
    import json, sys
    print(json.dumps({"type": "system", "subtype": "init", "session_id": "fake-session", "model": "fake-model"}), flush=True)
    turn = 0
    for line in sys.stdin:
        message = json.loads(line)
        words = message["message"]["content"]
        turn += 1
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [
            {"type": "tool_use", "id": "tool-%d" % turn, "name": "Bash", "input": {"command": "true"}}]}}), flush=True)
        print(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tool-%d" % turn}]}}), flush=True)
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": "echo: " + words}]}}), flush=True)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "echo: " + words}), flush=True)
    """#

    /// The script's path, made once.
    static let path: String = {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString.prefix(8)).py")
        try? Data(("#!/usr/bin/env python3\n" + script).utf8).write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }()
}
