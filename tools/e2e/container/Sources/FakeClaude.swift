// A stand-in for `claude -p` in stream JSON, as agent_protocol's tests have
// it (Tests/AgentWrapperTests/FakeClaude.swift): it says its session, then
// answers each turn with "echo: <words>" and ends the turn. Python, which
// the agent image has; agent-wrapper runs it in the guest as
// AGENT_WRAPPER_CLAUDE says, from the scratch folder on Sessions.

enum FakeClaude {
    static let script = #"""
    #!/usr/bin/env python3
    import json, sys
    print(json.dumps({"type": "system", "subtype": "init", "session_id": "e2e-session", "model": "fake-model"}), flush=True)
    turn = 0
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") != "user":
            continue
        words = message["message"]["content"]
        if not isinstance(words, str):
            words = " ".join(part.get("text", "") for part in words if isinstance(part, dict))
        turn += 1
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": "echo: " + words}]}}), flush=True)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "echo: " + words}), flush=True)
    """#
}
