#!/bin/bash
# Builds Visor Server, signs it (tools/sign_mac_app.sh), and installs it over the running one through the
# server's own relauncher (POST /api/restart): sessions mid-turn are marked
# interrupted, the new server resumes them with a nudge. Run from inside a
# Visor-driven session too — that session's turn is cut and resumed.
#
#   tools/deploy_server.sh [session id to carry on]   (defaults to $VISOR_SESSION)
set -euo pipefail
cd "$(dirname "$0")/.."
bazel build //applications/visor_menubar
ZIP="$(bazel cquery --output=files //applications/visor_menubar 2>/dev/null | head -1)"
rm -rf /tmp/vmb && mkdir -p /tmp/vmb && unzip -qo "$ZIP" -d /tmp/vmb
tools/sign_mac_app.sh "/tmp/vmb/Visor Server.app"
# Inside a Visor session, its agent token; otherwise the password, from
# the keychain (the first read asks once).
PW="${VISOR_TOKEN:-$(security find-generic-password -s com.LoganShire.VisorServer.macOS -a password -w 2>/dev/null || true)}"
SESSION="${1:-${VISOR_SESSION:-}}"
# The REST side is plain HTTP on localhost; TLS is Tailscale's, at the hostname.
curl -s --max-time 10 -X POST http://127.0.0.1:7434/api/restart \
  -H "Authorization: Bearer $PW" -H 'Content-Type: application/json' \
  -d "{\"path\":\"/tmp/vmb/Visor Server.app\",\"session\":\"$SESSION\"}"
echo
