#!/bin/bash
# Moving a Mac's Visor Server from 0.20 to 0.21, where nothing fronts it on
# 443 any more: the server listens on its own port, open to the network,
# and clients add it again from a new connection code.
#
#   tools/upgrade_0_21.sh prepare
#       Before the server is upgraded: writes its settings so the 0.21
#       server listens on every interface from its first start (the
#       connection code then names its Tailscale or LAN address, port 7433).
#   tools/upgrade_0_21.sh relink <this Mac's code file> <the other Mac's code file>
#       After both servers are on 0.21: links the two to each other, each
#       by the other's code, so the agents on one reach the sessions on the
#       other. The files are the ones written to ~/Downloads (a line with
#       `visor://connect?code=…`); they hold the passwords, so they stay there.
#       (A Mac cannot reach its own VPN address from itself: its own server
#       is asked on loopback, and its own client should name it so too.)
set -euo pipefail
DATA="$HOME/Library/Application Support/Visor"
case "${1:-}" in
  prepare)
    mkdir -p "$DATA"
    python3 - "$DATA/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
settings = {}
if os.path.exists(path):
    try: settings = json.load(open(path))
    except Exception: settings = {}
settings.setdefault("tlsIdentityPath", "")
settings.setdefault("publicAddress", "")
settings["reachableFromNetwork"] = True
json.dump(settings, open(path, "w"))
print("settings written:", path, "- the 0.21 server listens on every interface")
PY
    ;;
  relink)
    MINE="${2:?this Mac's code file}"; OTHER="${3:?the other Mac's code file}"
    python3 - "$MINE" "$OTHER" <<'PY'
import base64, json, sys, urllib.request
def read(path):
    for line in open(path):
        if line.startswith("visor://connect?code="):
            code = line.strip().split("code=", 1)[1]
            fields = json.loads(base64.urlsafe_b64decode(code + "=" * (-len(code) % 4)))
            return code, fields
    sys.exit("no code in " + path)
import subprocess, re
def local(host):
    # This computer cannot reach its own VPN address from itself (the way
    # such interfaces work on a Mac): its own server is asked on loopback.
    own = set(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", subprocess.run(["ifconfig"], capture_output=True, text=True).stdout))
    m = re.match(r"(https?)://([^/:]+)(:\d+)?(/.*)?$", host)
    if m and m.group(2) in own: return m.group(1) + "://127.0.0.1" + (m.group(3) or "") + (m.group(4) or "")
    return host
def link(server, code):
    # Each server takes the other's code: POST /api/link, with its own password.
    body = json.dumps({"type": "link", "text": code}).encode()
    request = urllib.request.Request(local(server["host"]) + "/api/link", data=body, method="POST",
                                     headers={"Authorization": "Bearer " + server["password"], "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as answer:
        reply = json.loads(answer.read())
    if reply.get("error"): sys.exit(server["name"] + ": " + reply["error"])
    print(server["name"], "now links to", json.loads(base64.urlsafe_b64decode(code + "=" * (-len(code) % 4)))["name"])
mine_code, mine = read(sys.argv[1])
other_code, other = read(sys.argv[2])
link(mine, other_code)
link(other, mine_code)
PY
    ;;
  *) sed -n 2,15p "$0"; exit 2 ;;
esac
