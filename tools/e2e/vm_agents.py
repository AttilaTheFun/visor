# In the test VM, over Visor's socket file (trusted: no password): a job
# queued for one kind of runner, its session awaited, its first reply,
# then a message sent and its answer. Prints one JSON line of what came
# back. Run with `python3 -I`.
#
#   vm_agents.py run <native|container> <seconds>
#   vm_agents.py stop <session id>

import http.client
import json
import os
import socket
import sys
import time

SOCKET = os.environ.get("VISOR_SOCKET") or os.path.expanduser("~/.visor/server.sock")


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("visor", timeout=30)

    def connect(self):
        stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stream.settimeout(30)
        stream.connect(SOCKET)
        self.sock = stream


def call(method, path, body=None):
    connection = UnixHTTP()
    connection.request(method, "/api" + path, body=None if body is None else json.dumps(body),
                       headers={"Content-Type": "application/json"})
    answer = connection.getresponse()
    data = answer.read()
    connection.close()
    if answer.status >= 300:
        raise RuntimeError(f"{method} {path}: {answer.status} {data[:200]!r}")
    return json.loads(data) if data else {}


def replies(session):
    entries = call("GET", f"/sessions/{session}/transcript").get("entries", [])
    return [entry.get("text", "") for entry in entries if entry.get("role") == "assistant"]


def until(seconds, what, check):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = check()
        if found:
            return found
        time.sleep(2)
    raise RuntimeError(f"no {what} within {seconds} s")


def run(kind, seconds):
    body = {"type": "job", "agent": "claude", "title": f"{kind.capitalize()} agent",
            "text": f"Reply with exactly: {kind} ok", "runsOn": kind}
    if kind == "native":
        body["cwd"] = os.path.expanduser("~/e2e-native")
        os.makedirs(body["cwd"], exist_ok=True)
    session = call("POST", "/jobs", body)["id"]
    until(seconds, f"{kind} session", lambda: any(s.get("id") == session for s in call("GET", "/sessions").get("sessions", [])))
    first = until(seconds, f"{kind} reply", lambda: next((r for r in replies(session) if f"{kind} ok" in r.lower()), None))
    call("POST", f"/sessions/{session}/send", {"text": f"Reply with exactly: {kind} ok again"})
    second = until(seconds, f"{kind} second reply",
                   lambda: next((r for r in replies(session) if f"{kind} ok again" in r.lower()), None))
    print(json.dumps({"kind": kind, "session": session, "first": first, "second": second}))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "run" and sys.argv[2] in ("native", "container"):
        run(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "stop":
        call("POST", f"/sessions/{sys.argv[2]}/stopAgent")
    else:
        sys.exit("usage: vm_agents.py run <native|container> <seconds> | stop <session id>")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as problem:
        sys.exit(f"vm_agents: {problem}")
