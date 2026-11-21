// A stand-in for `claude -p` in stream JSON, as agent_protocol's tests have
// it (Tests/AgentWrapperTests/FakeClaude.swift): it says its session (the
// one it's resumed with, `--resume <id>`, or a new one), then answers each
// turn with "echo: <words>" and ends the turn. As Claude does, it keeps its
// conversation in its Claude folder ($CLAUDE_CONFIG_DIR, else ~/.claude),
// `projects/<its folder's key>/<session>.jsonl`, the key its folder with
// every character but a letter or digit made "-": what a hand-back returns.
// Python, which the agent image has; agent-wrapper runs it in the guest as
// AGENT_WRAPPER_CLAUDE says, from the scratch folder on Sessions.

enum FakeClaude {
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, re, sys, uuid
    args = sys.argv[1:]
    session = args[args.index("--resume") + 1] if "--resume" in args else str(uuid.uuid4())
    folder = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    project = os.path.join(folder, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(os.getcwd())))
    os.makedirs(project, exist_ok=True)
    def keep(row):
        with open(os.path.join(project, session + ".jsonl"), "a") as kept:
            kept.write(json.dumps(row) + "\n")
    print(json.dumps({"type": "system", "subtype": "init", "session_id": session, "model": "fake-model"}), flush=True)
    turn = 0
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") != "user":
            continue
        words = message["message"]["content"]
        if not isinstance(words, str):
            words = " ".join(part.get("text", "") for part in words if isinstance(part, dict))
        turn += 1
        answer = "echo: " + words
        keep({"type": "user", "sessionId": session, "uuid": str(uuid.uuid4()), "message": {"role": "user", "content": words}})
        keep({"type": "assistant", "sessionId": session, "uuid": str(uuid.uuid4()),
              "message": {"id": "msg-%d" % turn, "role": "assistant", "content": [{"type": "text", "text": answer}]}})
        print(json.dumps({"type": "assistant", "message": {"id": "msg-%d" % turn, "content": [{"type": "text", "text": answer}]}}), flush=True)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": answer}), flush=True)
    """#
}
