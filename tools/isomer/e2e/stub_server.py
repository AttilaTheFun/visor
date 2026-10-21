#!/usr/bin/env python3
"""A stand-in Visor Server for the web client's end-to-end test: the site's
files, the REST calls and the WebSocket a client needs to reach a populated
sessions list (visor docs/protocol.md: "Who gets in", "REST", "WebSocket"),
on one plain-HTTP port. Standard library only.

  stub_server.py <site directory> <port> [--no-websocket]

`--no-websocket` is a road that carries no WebSocket (a reverse proxy that
does not pass upgrades): the upgrade is answered 501, and the client has to
follow by polling (`GET /api/sessions?since=`, `GET /api/sessions/<id>/state?
since=`, held while nothing changed, as visor's docs/protocol.md "Polling"
says). `GET /stub/stats` counts what was asked, for run.py.

What it answers is deliberately hostile to a 32-bit client: token counts,
context sizes and revisions past 2^31, a count past 2^53's reach of exact
doubles, a negative, a fraction — the numbers a wasm32 build's `Int` cannot
hold. (Visor 0.19's web client died on the first real session whose tokens
passed 2^31: `Int(Double)` traps out of range.) The names in SESSIONS are
what run.py looks for on the page.
"""
import base64, hashlib, http.server, json, os, struct, sys, threading, time

# The list's revision, and a state's: a counter a server keeps from its
# start, so it is kept small here. (Past 2^31 a wasm32 client reads it as
# nothing — as the transcript revision below is read — and would ask again
# without `since`: a loop, not a hold.)
REVISION = 42
HOLD = 3.0
NO_WEBSOCKET = "--no-websocket" in sys.argv
STATS = {"hellos": 0, "peers": 0, "upgrades": 0, "upgradesRefused": 0, "sessionsLists": 0, "sessionsPolls": 0, "statePolls": 0, "earlier": 0}

NOW = 1791100000.0
SESSIONS = [
    {"id": "stub-big", "title": "Past two billion", "agent": "claude", "cwd": "/Users/stub/big", "preview": "Counting very high.",
     "created": NOW - 86400, "updated": NOW - 60, "busy": False, "ended": False, "archived": False, "skipPermissions": True,
     "model": "opus", "contextUsed": 3_000_000_000, "contextLimit": 5_000_000_000,
     "usage": {"input": 3_302_964_500, "cached": 3_100_000_000, "output": 9_007_199_254_740_993, "cost": 12345.67}},
    {"id": "stub-odd", "title": "Odd numbers", "agent": "claude", "cwd": "/Users/stub/odd", "preview": "Negative and fractional.",
     "created": NOW - 7200, "updated": NOW - 30, "busy": True, "ended": False, "archived": False, "skipPermissions": False,
     "contextUsed": -5, "contextLimit": 200000.75,
     "usage": {"input": -1, "cached": 1e300, "output": 2_147_483_648, "cost": 0.004}},
    {"id": "stub-long", "title": "Long lines", "agent": "claude", "cwd": "/Users/stub/long", "preview": "A code block wider than a phone.",
     "created": NOW - 3600, "updated": NOW - 90, "busy": False, "ended": False, "archived": False, "skipPermissions": False},
    {"id": "stub-pictures", "title": "Pictures", "agent": "claude", "cwd": "/Users/stub/pictures", "preview": "Screenshots in a row.",
     "created": NOW - 3000, "updated": NOW - 120, "busy": False, "ended": False, "archived": False, "skipPermissions": False},
]
# "Long lines"' transcript: a code block whose lines are wider than a phone,
# one of them a single word (a connection code), for the checks that its
# lines wrap within the screen (code_block_check.js, code_block_android.py).
CODE_WORD = "vsr1-" + "eyJ2IjoxLCJuYW1lIjoiU3R1YiIsImhvc3QiOiJodHRwOi8vMTAuMC4yLjI6ODc2NSIsInBhc3N3b3JkIjoiIiwiYXV0aCI6Im5vbmUifQ" * 2
CODE_LINE = "swift test --filter LayoutRegressionTests.testACodeBlockWraps --parallel --num-workers 8 --enable-code-coverage"
LONG_LINES = [
    {"id": "long-1", "role": "user", "text": "What is the connection code?"},
    {"id": "long-2", "role": "assistant", "text": "Paste this into Visor:\n\n```\n" + CODE_WORD + "\n" + CODE_LINE + "\n```\n\nIt is one long word."},
]
# "Pictures"' transcript: four phone screenshots in one of your messages,
# wider together than it (a carousel within its width, the words still
# there), and two in another, which fit (a row on its side, the trailing). Their sizes only: a
# thumbnail's frame is reserved from its size before its bytes arrive, which
# the stub does not serve.
SHOT = {"width": 1179, "height": 2556}
PICTURES = [
    {"id": "pics-1", "role": "user", "text": "Four screenshots of the sign-in screen.",
     "images": [f"/Users/stub/shots/four-{i}.png" for i in range(1, 5)], "imageSizes": [SHOT] * 4},
    {"id": "pics-2", "role": "user", "text": "And the two that changed.",
     "images": [f"/Users/stub/shots/two-{i}.png" for i in range(1, 3)], "imageSizes": [SHOT] * 2},
]
TRANSCRIPTS = {"stub-long": LONG_LINES, "stub-pictures": PICTURES}
TRANSCRIPT_REVISION = 7
CATALOGS = [{"agent": "claude", "available": True, "defaultModel": "opus", "models": [],
             "account": {"plan": "Stub", "subscription": True, "updated": NOW - 5_000_000_000,
                         "limits": [{"name": "5-hour", "used": 7.5, "resets": NOW + 4_000_000_000},
                                    {"name": "Credits", "left": 9_000_000_000, "total": 10_000_000_000, "unit": "credits"}]}}]
WELCOME = {"type": "welcome", "host": "Stub", "sessions": SESSIONS, "catalogs": CATALOGS, "revision": REVISION}


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args): pass

    def answer(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            STATS["upgrades"] += 1
            if NO_WEBSOCKET:
                STATS["upgradesRefused"] += 1
                return self.answer({"type": "error", "error": "this road carries no WebSocket"}, 501)
            return self.websocket()
        path, _, query = self.path.partition("?")
        since = dict(part.split("=", 1) for part in query.split("&") if "=" in part).get("since")
        if path == "/api/hello":
            STATS["hellos"] += 1
            return self.answer({"type": "hello", "host": "Stub", "login": "stub@example.com", "token": "stub-token",
                                "id": "stub-server", "addresses": ["https://stub.visor.test"]})
        if path == "/api/peers":
            # The network as the stub knows it (visor 0.22): itself alone.
            STATS["peers"] += 1
            return self.answer({"type": "peers", "id": "stub-server", "host": "Stub", "addresses": ["https://stub.visor.test"], "peers": []})
        if path == "/stub/stats":
            return self.answer(STATS)
        if path == "/api/sessions":
            # Polled: held while the list is at the revision the client has.
            STATS["sessionsLists"] += 1
            if since is not None:
                STATS["sessionsPolls"] += 1
                if since == str(REVISION): time.sleep(HOLD)
            return self.answer(WELCOME)
        if path.startswith("/api/sessions/") and path.endswith("/state"):
            STATS["statePolls"] += 1
            if since == str(REVISION): time.sleep(HOLD)
            return self.answer({"type": "ephemeral", "session": path.split("/")[3], "revision": REVISION})
        if path.startswith("/api/sessions/") and path.endswith("/earlier"):
            STATS["earlier"] += 1
            return self.answer({"type": "earlier", "session": path.split("/")[3], "messages": []})
        if path.startswith("/api/sessions/") and path.endswith("/commands"):
            return self.answer({"type": "commands", "commands": []})
        held = next((s for s in TRANSCRIPTS if path == f"/api/sessions/{s}/transcript"), None)
        if held:
            # The whole transcript, then (asked again at its revision) held
            # and answered with nothing new, as a server holds a poll.
            if since == str(TRANSCRIPT_REVISION):
                time.sleep(HOLD)
                return self.answer({"type": "transcript", "session": held, "revision": TRANSCRIPT_REVISION,
                                    "generation": 1, "entries": []})
            return self.answer({"type": "transcript", "session": held, "revision": TRANSCRIPT_REVISION,
                                "generation": 1, "reset": True, "entries": TRANSCRIPTS[held]})
        if path.startswith("/api/sessions/") and path.endswith("/transcript"):
            # One empty page whose revision and generation are past 2^31 too.
            return self.answer({"type": "transcript", "session": path.split("/")[3], "revision": 6_000_000_000,
                                "generation": 3_000_000_000, "reset": True, "messages": []})
        if path == "/api/folders":
            return self.answer({"type": "folders", "folders": []})
        if path.startswith("/api/"):
            return self.answer({"type": "error", "error": "the stub does not answer " + path}, 404)
        return super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length: self.rfile.read(length)
        self.answer({"type": "ok"})

    # --- The live channel: login -> welcome, ping -> pong, subscribe -> ephemeral.

    def websocket(self):
        accept = base64.b64encode(hashlib.sha1(
            (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        super().end_headers()
        self.close_connection = True
        while True:
            message = self.read_frame()
            if message is None: return
            try: envelope = json.loads(message)
            except ValueError: continue
            kind = envelope.get("type")
            if kind == "login": self.send_frame(WELCOME)
            elif kind == "ping": self.send_frame({"type": "pong"})
            elif kind == "subscribe": self.send_frame({"type": "ephemeral", "session": envelope.get("session"), "revision": REVISION})

    def read_frame(self):
        try:
            head = self.rfile.read(2)
            if len(head) < 2: return None
            opcode, length = head[0] & 0x0F, head[1] & 0x7F
            if length == 126: length = struct.unpack(">H", self.rfile.read(2))[0]
            elif length == 127: length = struct.unpack(">Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(length)))
        except OSError:
            return None
        if opcode == 8: return None
        if opcode == 9:  # a ping frame: pong it
            self.wfile.write(bytes([0x8A, len(data)]) + data)
            return ""
        return data.decode("utf-8", "replace") if opcode in (1, 2) else ""

    def send_frame(self, value):
        data = json.dumps(value).encode()
        head = bytes([0x81])
        if len(data) < 126: head += bytes([len(data)])
        elif len(data) < 65536: head += bytes([126]) + struct.pack(">H", len(data))
        else: head += bytes([127]) + struct.pack(">Q", len(data))
        try: self.wfile.write(head + data); self.wfile.flush()
        except OSError: pass


if __name__ == "__main__":
    site, port = sys.argv[1], int(sys.argv[2])
    sys.stdout.write("[stub] " + ("no WebSocket: upgrades answered 501\n" if NO_WEBSOCKET else "WebSocket on\n")); sys.stdout.flush()
    os.chdir(site)
    # A backlog past socketserver's 5: the page asks for a dozen runtime
    # modules at once, and a reset one leaves it blank with no error.
    class Server(http.server.ThreadingHTTPServer):
        request_queue_size = 128
    server = Server(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.serve_forever()
