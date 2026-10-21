#!/usr/bin/env python3
"""check.py: a local suite's result on a commit, as a GitHub check run.

The Isomer repositories had no hosted CI (2026-10-19): their suites run on
the maintainer's Mac. Each posts its
result to the commit it tested as a check run of the agent's GitHub App
(`agent-token gh claude`), so the commit's dot on GitHub, a pull request's
checks and Reviews' "CI on <head>" read them as they read a hosted run's,
and main's branch protection can require them by name (`local/<suite>`).

    check.py start  <name> [--sha SHA]
    check.py finish <name> success|failure|neutral|cancelled [--summary TEXT] [--url URL] [--sha SHA]
    check.py run    <name> [--sha SHA] [--url URL] -- <command…>

`run` starts the check, runs the command, and finishes it by the command's
exit status, the last lines of its output as the summary (the output still
goes to stdout). SHA defaults to HEAD, which must be pushed: GitHub takes
checks only on commits it has. A suite run on uncommitted changes has no
commit to report to: commit first.
"""
import argparse, datetime, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


def repo():
    url = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)
    if not match:
        sys.exit(f"check.py: origin is not on GitHub ({url})")
    return match.group(1)


# In `run`, a check that cannot be posted (no network, the app without the
# Checks permission) is a warning: the suite still runs and its exit status
# stands.
SOFT = False


def api(method, path, body=None):
    """The app's REST call; the parsed answer, or exit with GitHub's message
    (a warning and None when SOFT)."""
    env = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", ""))
    cmd = ["agent-token", "gh", "claude", "api", "-X", method, path]
    if body is not None:
        cmd += ["--input", "-"]
    done = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                          capture_output=True, text=True, env=env)
    if done.returncode != 0:
        message = f"check.py: {method} {path}: {(done.stdout + done.stderr).strip()[:400]}"
        if SOFT:
            print(message + " (not posted)", file=sys.stderr)
            return None
        sys.exit(message)
    return json.loads(done.stdout) if done.stdout.strip() else {}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def latest(name, sha):
    """The commit's newest check run of that name, if any."""
    runs = (api("GET", f"repos/{repo()}/commits/{sha}/check-runs?check_name={name}&filter=latest") or {}).get("check_runs", [])
    return runs[0] if runs else None


def start(name, sha):
    return api("POST", f"repos/{repo()}/check-runs",
               {"name": name, "head_sha": sha, "status": "in_progress", "started_at": now()})


def finish(name, sha, conclusion, summary="", url=None):
    body = {"status": "completed", "conclusion": conclusion, "completed_at": now(),
            "output": {"title": f"{name}: {conclusion}", "summary": summary[-60000:] or conclusion}}
    if url:
        body["details_url"] = url
    run = latest(name, sha)
    if run and run.get("status") != "completed":
        return api("PATCH", f"repos/{repo()}/check-runs/{run['id']}", body)
    return api("POST", f"repos/{repo()}/check-runs", {"name": name, "head_sha": sha, **body})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["start", "finish", "run"])
    parser.add_argument("name")
    parser.add_argument("conclusion", nargs="?")
    parser.add_argument("--sha")
    parser.add_argument("--summary", default="")
    parser.add_argument("--url")
    # The command is everything after `--`, split off before parsing: left
    # to argparse, its first word filled the optional `conclusion` (`bazel
    # test //...` ran /bin/test).
    argv = sys.argv[1:]
    command = argv[argv.index("--") + 1:] if "--" in argv else []
    args = parser.parse_args(argv[:argv.index("--")] if "--" in argv else argv)
    sha = args.sha or git("rev-parse", "HEAD")
    if args.action == "start":
        start(args.name, sha)
    elif args.action == "finish":
        if args.conclusion not in ("success", "failure", "neutral", "cancelled"):
            sys.exit("check.py finish: success, failure, neutral or cancelled")
        finish(args.name, sha, args.conclusion, args.summary, args.url)
    else:
        if not command:
            sys.exit("check.py run <name> -- <command…>")
        global SOFT
        SOFT = True
        start(args.name, sha)
        lines = []
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
        code = proc.wait()
        tail = "".join(lines[-40:])
        finish(args.name, sha, "success" if code == 0 else "failure", f"```\n{tail}\n```", args.url)
        sys.exit(code)


if __name__ == "__main__":
    main()
