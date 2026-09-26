#!/bin/bash
# Signs a Mac app with the builder's own team, so each build is signed the
# same way — which is what lets the keychain hand the app its secrets
# without asking. The team is VISOR_TEAM_ID from .bazelrc.user; the identity
# is that team's "Developer ID Application" certificate in the keychain if
# there is one (what a release needs), else its "Apple Development" one.
# Hardened runtime and a secure timestamp, as notarization wants.
# Keychain items the app writes are then read back by every later build
# without a prompt.
#
#   tools/sign_mac_app.sh <path to .app>
set -euo pipefail
APP="${1:?path to the .app}"
cd "$(dirname "$0")/.."
TEAM="$(sed -n 's/.*VISOR_TEAM_ID=\([A-Z0-9]*\).*/\1/p' .bazelrc.user 2>/dev/null | head -1)"
[ -n "$TEAM" ] || { echo "No VISOR_TEAM_ID in .bazelrc.user (tools/signing)" >&2; exit 1; }
IDENTITY="$(python3 - "$TEAM" <<'PY'
import re, subprocess, sys
team = sys.argv[1]
listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
found = {}
for sha, name in re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', listing):
    pem = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p", "-c", name], capture_output=True, text=True).stdout
    for block in pem.split("SHA-1 hash: ")[1:]:
        if not block.startswith(sha):
            continue
        cert = block[block.index("-----BEGIN"):]
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=cert, capture_output=True, text=True).stdout
        if f"OU={team}" in subject.replace(" ", "") or f"OU = {team}" in subject:
            kind = "developer-id" if name.startswith("Developer ID Application") else "development" if name.startswith("Apple Development") else None
            if kind:
                found.setdefault(kind, sha)
print(found.get("developer-id") or found.get("development") or "")
PY
)"
[ -n "$IDENTITY" ] || { echo "No signing identity for team $TEAM in the keychain (Xcode → Settings → Accounts)" >&2; exit 1; }
# What the app is, as far as the keychain goes: its bundle id and the team,
# not the one certificate that signed it — so a build signed with the
# team's other certificate, or a renewed one, is still the same app.
BUNDLE="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
REQUIREMENT="designated => identifier \"$BUNDLE\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\""
codesign --force --options runtime --timestamp --sign "$IDENTITY" -r="$REQUIREMENT" "$APP"
codesign --verify --strict "$APP"
echo "Signed $(basename "$APP") with $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/.*"\(.*\)".*/\1/' | head -1)"
