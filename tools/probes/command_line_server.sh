#!/bin/bash
# The command-line server (Linux), tried as its user would: a password made, the server run in the
# terminal and checked with the terminal probe, stopped through its REST side; then started in the
# background, restarted through /api/restart (the new process waits for the old to go), checked
# again, and stopped with `visor-server stop`. Needs no agent CLI and no Tailscale.
#   tools/probes/command_line_server.sh [path to visor-server]   (default .build/debug/visor-server)
set -uo pipefail
cd "$(dirname "$0")/../.."
BIN="${1:-.build/debug/visor-server}"
PORT=7633
failures=0
check() { if "$@"; then echo "ok: $*"; else echo "FAILED: $*"; failures=$((failures + 1)); fi; }

PW="$($BIN password)"
check test ${#PW} -ge 12

# In the terminal, stopped through the REST side.
$BIN run --port $PORT > /tmp/visor-server-run.log 2>&1 &
sleep 2
export VISOR_PORT=$PORT VISOR_TOKEN="$PW"
check env QUIT=1 node tools/probes/terminal.mjs
sleep 1
check grep -q "session started: probe-terminal" /tmp/visor-server-run.log

# In the background: started, restarted, stopped.
check $BIN start --port $PORT
sleep 2
check $BIN status
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/visor"
FIRST=$(cut -d' ' -f1 "$DATA/visor-server.pid")
curl -s -X POST -H "Authorization: Bearer $PW" http://127.0.0.1:$((PORT + 1))/api/restart -d '{}' > /dev/null
sleep 4
SECOND=$(cut -d' ' -f1 "$DATA/visor-server.pid")
check test "$FIRST" != "$SECOND"
check bash -c "! kill -0 $FIRST 2>/dev/null"
check node tools/probes/terminal.mjs
check $BIN stop
check bash -c "! kill -0 $SECOND 2>/dev/null"
echo "--- the background server's log"
cat "$DATA/visor-server.log"
echo "failures $failures"
exit $failures
