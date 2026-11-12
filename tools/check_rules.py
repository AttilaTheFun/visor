#!/usr/bin/env python3
"""The rules of AGENTS.md that must hold, checked: CI's `rules` job, on
every pull request and every commit on main. AGENTS.md says why each holds;
this says where one doesn't, with the file and line.

    tools/check_rules.py [--commits <base>..<head>]

Checked in every file git tracks (third_party/ aside):
- no signing material: no profiles, certificates, .p8 or .p12 files; no
  private key's body; no device UDID; no Apple team id given a value (the
  team comes from the builder's own .bazelrc.user, tools/signing);
- every Swift target compiled the strict way: `copts = STRICT_SWIFT`
  (tools/swift/defs.bzl), in the Swift 6 language mode with warnings as
  errors;
- no `nonisolated(unsafe)` and no `@unchecked Sendable` (but the FFI
  adapters below, with why);
- no Combine;
- no Foundation networking or UserDefaults in visor_client or visor_ui,
  which build on Isomer as they do on Apple's platforms;
- no conditional compilation or platform check in the server library
  (libraries/visor_server) or the libraries below it (libraries/visor_agent,
  libraries/visor_system): what differs is their ServerPlatform's or
  SystemPlatform's.
With --commits, the pull request's commits carry no attribution lines.

Exits 1 when anything breaks a rule, saying what. Standard library only.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Each `@unchecked Sendable` allowed, by file and how many: the reason is
# beside it in the code. Visor's own FFI (web, Android) adapts host objects
# (JavaScript, Kotlin) that are used only from the main thread the runtime
# runs on, and that its bridge generator makes non-Sendable.
UNCHECKED_ALLOWED = {"libraries/visor_services_ffi/Sources/Bridges.swift": 3}

# The libraries with no conditional compilation and no platform checks, and
# where what differs between systems goes instead.
PLATFORM_FREE = {"libraries/visor_server/": "ServerPlatform", "libraries/visor_agent/": "SystemPlatform",
                 "libraries/visor_system/": "SystemPlatform"}

SIGNING_FILES = re.compile(r"\.(mobileprovision|provisionprofile|p12|pfx|p8|cer|certSigningRequest)$", re.I)
PRIVATE_KEY = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\"\\n+]*[A-Za-z0-9+/=]{64,}")
DEVICE_UDID = re.compile(r"\b0000[0-9]{4}-[0-9A-Fa-f]{16}\b")
TEAM_IDS = [
    re.compile(r"VISOR_TEAM_ID=([A-Z0-9]{10})\b"),
    re.compile(r"DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\b"),
    re.compile(r"(?:team-identifier|TeamIdentifier)</key>\s*(?:<array>\s*)?<string>([A-Z0-9]{10})</string>"),
    re.compile(r"\b([A-Z0-9]{10})\.(?:com\.LoganShire|group\.com\.LoganShire)\b"),
]
SWIFT_RULES = ("swift_library", "swift_binary", "swift_test", "swift_compiler_plugin")
NETWORKING = re.compile(r"\b(URLSession|URLRequest|UserDefaults|NSUserDefaults)\b")

problems = []


def problem(where, what):
    problems.append(f"{where}: {what}")


def tracked():
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout
    # third_party/ is others' code.
    return [name for name in files.decode().split("\0") if name and not name.startswith("third_party/")]


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def code(text):
    """The text with comments and string literals blanked, line for line."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r'"""(?:.|\n)*?"""', lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    return re.sub(r"//[^\n]*", "", text)


def check_signing(name, text):
    if SIGNING_FILES.search(name):
        problem(name, "signing material (a profile, certificate or key) is never checked in")
    for pattern, what in ((PRIVATE_KEY, "a private key"), (DEVICE_UDID, "a device's UDID")):
        for found in pattern.finditer(text):
            problem(f"{name}:{line_of(text, found.start())}", f"{what} is never checked in")
    for pattern in TEAM_IDS:
        for found in pattern.finditer(text):
            problem(f"{name}:{line_of(text, found.start())}",
                    f"an Apple team id ({found.group(1)[:2]}…) is never checked in: it comes from .bazelrc.user")


def check_build(name, text):
    for found in re.finditer(r"^(\w+)\(\n(.*?)^\)", text, re.M | re.S):
        kind, body = found.group(1), found.group(2)
        if kind not in SWIFT_RULES:
            continue
        if not re.search(r"^\s*copts\s*=\s*STRICT_SWIFT\b", body, re.M):
            target = re.search(r'name\s*=\s*"([^"]+)"', body)
            problem(f"{name}:{line_of(text, found.start())}",
                    f"{kind} {target.group(1) if target else '?'} takes `copts = STRICT_SWIFT` (tools/swift/defs.bzl)")


def check_swift(name, text):
    body = code(text)
    unchecked = [found for found in re.finditer(r"@unchecked\s+Sendable", body)]
    if len(unchecked) > UNCHECKED_ALLOWED.get(name, 0):
        for found in unchecked:
            problem(f"{name}:{line_of(body, found.start())}",
                    "no `@unchecked Sendable`: an actor, the main actor, or a Mutex for what is truly shared")
    for found in re.finditer(r"nonisolated\s*\(\s*unsafe\s*\)", body):
        problem(f"{name}:{line_of(body, found.start())}", "no `nonisolated(unsafe)`")
    for found in re.finditer(r"^\s*(?:@\w+\s+)*import\s+(?:\w+\s+)?Combine\b", body, re.M):
        problem(f"{name}:{line_of(body, found.start())}", "no Combine: async/await only")
    if name.startswith(("libraries/visor_client/", "libraries/visor_ui/")):
        for found in NETWORKING.finditer(body):
            problem(f"{name}:{line_of(body, found.start())}",
                    f"no {found.group(1)} in visor_client or visor_ui: the host is reached through visor_services")
    for library, platform in PLATFORM_FREE.items():
        if not name.startswith(library):
            continue
        for found in re.finditer(r"^\s*#(if|elseif)\b|#(available|unavailable)\b", body, re.M):
            problem(f"{name}:{line_of(body, found.start())}",
                    f"no conditional compilation or platform check in {library.rstrip('/')}: a {platform} member")


def check_commits(span):
    listed = subprocess.run(["git", "-C", str(ROOT), "log", "--format=%H%x00%B%x01", span],
                            capture_output=True, check=True).stdout.decode()
    for record in listed.split("\x01"):
        if not record.strip():
            continue
        commit, _, message = record.strip().partition("\x00")
        for line in message.splitlines():
            if re.match(r"\s*co-authored-by:", line, re.I) or "Generated with [Claude Code]" in line:
                problem(f"commit {commit[:7]}", f"no attribution lines in commits: {line.strip()[:60]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--commits", help="a pull request's commits, <base>..<head>, to check for attribution lines")
    args = parser.parse_args()
    for name in tracked():
        path = ROOT / name
        if not path.is_file():
            continue
        if SIGNING_FILES.search(name):
            check_signing(name, "")
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        check_signing(name, text)
        if path.name in ("BUILD.bazel", "BUILD"):
            check_build(name, text)
        elif name.endswith(".swift"):
            check_swift(name, text)
    if args.commits:
        check_commits(args.commits)
    for line in problems:
        print(line)
    if problems:
        print(f"{len(problems)} broken: AGENTS.md says why each holds", file=sys.stderr)
        sys.exit(1)
    print("Every rule holds.")


if __name__ == "__main__":
    main()
