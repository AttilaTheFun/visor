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
# A capability (push) comes with a provisioning profile for the app, made
# for the kind of certificate signing it (tools/mint_profile): embedded, and
# the app signed with what it grants. An app with none (the server) is
# signed as it is.
ENTITLEMENTS=()
PROFILE="$(python3 - "$BUNDLE" "$TEAM" "$IDENTITY" <<'PY'
import glob, os, plistlib, subprocess, sys
bundle, team, identity = sys.argv[1:4]
name = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
developer_id = any(identity in line and "Developer ID Application" in line for line in name.splitlines())
best = None
for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.provisionprofile")):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    try:
        profile = plistlib.loads(raw)
    except Exception:
        continue
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.application-identifier") != f"{team}.{bundle}":
        continue
    if bool(profile.get("ProvisionsAllDevices")) != developer_id:
        continue
    if best is None or profile.get("CreationDate") > best[1]:
        best = (path, profile.get("CreationDate"))
print(best[0] if best else "")
PY
)"
if [ -n "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    WANTED="$(mktemp -t visor-entitlements).plist"
    python3 - "$PROFILE" "$WANTED" <<'PY'
import plistlib, subprocess, sys
profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True).stdout)
granted = profile.get("Entitlements", {})
keep = ["com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.developer.aps-environment"]
with open(sys.argv[2], "wb") as f:
    plistlib.dump({k: granted[k] for k in keep if k in granted}, f)
PY
    ENTITLEMENTS=(--entitlements "$WANTED")
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} -r="$REQUIREMENT" "$APP"
codesign --verify --strict "$APP"
echo "Signed $(basename "$APP") with $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/.*"\(.*\)".*/\1/' | head -1)"
