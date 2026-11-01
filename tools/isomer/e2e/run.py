#!/usr/bin/env python3
"""End-to-end test of the web client against a server: the wasm build, in
headless Chrome, logs in to a stand-in Visor Server over real HTTP and a
real WebSocket and must show its sessions with nothing uncaught.

  tools/isomer/e2e/run.py [site directory]

The snapshot tests draw the client from a fixture; this one makes it talk.
It exists because Visor 0.19's web client passed every snapshot and died on
a real sessions list (a token count past 2^31; wasm32's Int is 32
bits), so the stub's numbers are the ones a 32-bit client can't hold
(stub_server.py). The page reaches the stub through a small shim that sends
the client's https:// and wss:// requests for the stub's name to the local
port: the client's own code is the released build, unmodified.

It runs three times: with the stub's WebSocket; with the upgrade refused (a
reverse proxy that passes no WebSockets), when the list must still appear,
by polling — the socket and push are accessories for live updates; the
client has to work on plain HTTP (visor 0.21); and with nothing saved and no
shim at all, when the page, served by the stub itself, must find the server
at its own origin (index.html's same-origin computer) — an `http://host:port`
address, socket and API found from it.
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
PORT = 8795
STUB = "stub.visor.test"
SHIM = """<script>
// tools/isomer/e2e: the client asks https://%(stub)s and wss://%(stub)s; both go to the stub server on this page's own origin.
(() => {
  const local = location.host;
  const realFetch = window.fetch.bind(window);
  window.fetch = (url, options) => realFetch(String(url).replace("https://%(stub)s", "http://" + local), options);
  const RealSocket = window.WebSocket;
  window.WebSocket = function (url, protocols) { return new RealSocket(String(url).replace("wss://%(stub)s", "ws://" + local), protocols); };
  window.WebSocket.prototype = RealSocket.prototype;
  for (const k of ["CONNECTING", "OPEN", "CLOSING", "CLOSED"]) window.WebSocket[k] = RealSocket[k];
  if (!localStorage.getItem("visor.hosts")) localStorage.setItem("visor.hosts", JSON.stringify([
    { name: "Stub", id: "stub-computer", address: "%(stub)s", provider: "tailscale", everConnected: true, secret: "" }]));
})();
</script>""" % {"stub": STUB}

def encode(record, out):
    """The screencast's frames (page_check.js's PAGE_CHECK_RECORD) as an MP4,
    each frame held until the next came."""
    frames = json.load(open(os.path.join(record, "frames.json")))
    # No ffmpeg (a CI runner without it): the review keeps its screens, without a recording.
    if not frames or not shutil.which("ffmpeg"):
        return False
    with open(os.path.join(record, "list.txt"), "w") as f:
        for i, frame in enumerate(frames):
            hold = (frames[i + 1]["time"] - frame["time"]) if i + 1 < len(frames) else 1.0
            f.write(f"file 'frames/{frame['name']}'\nduration {max(hold, 0.01):.3f}\n")
        f.write(f"file 'frames/{frames[-1]['name']}'\n")
    done = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(record, "list.txt"),
                           "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p", "-c:v", "libx264", "-r", "30", out])
    return done.returncode == 0

def write_review(review, site, results):
    """The e2e as a UI test for the review server's store: a manifest per
    orientation (target web-e2e), an item per road with its last screen and
    its recording."""
    page = open(os.path.join(site, "index.html")).read()
    version = (re.search(r'"host.appVersion": "([^"]+)"', page) or [None, "?"])[1]
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    for orientation, roads in results.items():
        out = os.path.join(review, f"web-e2e-{orientation}")
        os.makedirs(out, exist_ok=True)
        items = []
        for road, (ok, record, lines) in roads.items():
            item = {"name": road, "status": "passed" if ok else "failed", "log": "\n".join(lines)}
            if os.path.exists(os.path.join(record, "final.png")):
                shutil.copy(os.path.join(record, "final.png"), os.path.join(out, f"{road}.png"))
                item["capture"] = f"{road}.png"
            if encode(record, os.path.join(out, f"{road}.mp4")):
                item["video"] = f"{road}.mp4"
            items.append(item)
        manifest = {"schema": 1, "app": "Visor Isomer", "version": version, "release": version.split(" ")[0], "commit": commit,
                    "kind": "ui-test", "target": "web-e2e", "device": "Chrome, headless", "orientation": orientation,
                    "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items}
        json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
        print(f"[e2e] review: {out}", flush=True)

def main():
    # The site as built here, or — `tools/isomer/e2e/run.py <site directory>` — one
    # already built (a published copy: the test of a release). With
    # `--review <dir>` it also runs in a landscape window, records each road
    # and writes the review store's manifests there.
    parser = argparse.ArgumentParser()
    parser.add_argument("site", nargs="?")
    parser.add_argument("--review")
    args = parser.parse_args()
    if args.site:
        built = os.path.abspath(args.site)
    else:
        subprocess.run(["bazel", "build", "-c", "opt", "//applications/visor_web:visor_web_site"], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        built = subprocess.run(["bazel", "cquery", "-c", "opt", "--output=files", "//applications/visor_web:visor_web_site"],
                               cwd=ROOT, capture_output=True, text=True).stdout.split()[0]
        # Relative to the execution root: the checkout has no bazel-out link
        # where Bazel makes none (Visor's agent image).
        root = subprocess.run(["bazel", "info", "-c", "opt", "execution_root"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        built = os.path.join(root, built)
    site = tempfile.mkdtemp(prefix="visor-e2e-")
    server = None
    try:
        shutil.copytree(os.path.join(ROOT, built), site, dirs_exist_ok=True, symlinks=False,
                        ignore=shutil.ignore_patterns(".git", "preview"))
        subprocess.run(["chmod", "-R", "u+w", site])
        index = os.path.join(site, "index.html")
        page = open(index).read()
        assert "<head>" in page
        failed = []
        windows = [("portrait", "412,900")] + ([("landscape", "900,412")] if args.review else [])
        results = {}
        for orientation, window in windows:
          for road in ("websocket", "polling", "same-origin"):
            open(index, "w").write(page if road == "same-origin" else page.replace("<head>", "<head>" + SHIM, 1))
            server = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools/isomer/e2e/stub_server.py"), site, str(PORT)]
                                      + (["--no-websocket"] if road == "polling" else []))
            for _ in range(50):
                try: urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/hello", timeout=1); break
                except OSError: time.sleep(0.2)
            where = road if orientation == "portrait" else f"{road} ({orientation})"
            lines, record = [], tempfile.mkdtemp(prefix="visor-e2e-record-")
            def report(ok, line):
                text = ("[e2e] ok    " if ok else "[e2e] FAIL  ") + line
                print(text, flush=True)
                lines.append(text)
                if not ok: failed.append(line)
            # Both sessions are listed: every number in the welcome was decoded.
            # Where the upgrade is refused, the browser's complaint about it
            # (and the 501) is the point, not a problem; the page is left
            # open a moment after the list showed, for the first poll.
            for title in ("Past two billion", "Odd numbers"):
                env = dict(os.environ, PAGE_CHECK_WINDOW=window)
                if road == "polling": env.update(PAGE_CHECK_EXPECTED=r"WebSocket|HTTP 501", PAGE_CHECK_LINGER="2000")
                if args.review and title == "Past two billion": env["PAGE_CHECK_RECORD"] = record
                result = subprocess.run(["node", os.path.join(ROOT, "tools/isomer/e2e/page_check.js"), f"http://127.0.0.1:{PORT}/", title, "45"],
                                        capture_output=True, text=True, env=env)
                try: seen = json.loads(result.stdout)
                except ValueError: seen = {"ok": False, "problems": [result.stdout + result.stderr]}
                report(seen.get("ok"), f"{where}: the sessions list shows \"{title}\", nothing uncaught" + ("" if seen.get("ok") else ": " + json.dumps(seen)))
            stats = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/stub/stats", timeout=5).read())
            if road == "polling":
                # The list came by asking again, after the upgrade was refused.
                report(stats["upgradesRefused"] >= 1 and stats["sessionsPolls"] >= 1, f"{where}: the upgrade was refused and the list polled ({stats})")
            if road == "same-origin":
                # Found by hello, then the socket at the origin itself.
                report(stats["hellos"] >= 1 and stats["upgrades"] >= 1, f"{where}: the page found the server at its own origin ({stats})")
            results.setdefault(orientation, {})[road] = (all(l.startswith("[e2e] ok") for l in lines), record, lines)
            server.terminate()
            server.wait()
            server = None
        if args.review:
            write_review(args.review, site, results)
        print("[e2e] FAILED" if failed else "[e2e] all passed")
        return 1 if failed else 0
    finally:
        if server: server.terminate()
        shutil.rmtree(site, ignore_errors=True)

if __name__ == "__main__":
    sys.exit(main())
