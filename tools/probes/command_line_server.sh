#!/bin/bash
# The command-line server (Linux), tried as its user would: a password made, the server run in the
# terminal and checked with the server probe, stopped through its REST side; then started in the
# background, restarted through /api/restart (the new process waits for the old to go), checked
# again, restarted once more after its program file was replaced (as an update, or a build copied
# in by hand, replaces it), and stopped with `visor-server stop`. Needs no agent CLI.
#   tools/probes/command_line_server.sh [path to visor-server]   (default .build/debug/visor-server)
set -uo pipefail
cd "$(dirname "$0")/../.."
BIN="${1:-.build/debug/visor-server}"
PORT=7633
failures=0
check() { if "$@"; then echo "ok: $*"; else echo "FAILED: $*"; failures=$((failures + 1)); fi; }
# Gone: no such process, or one that has exited and not been reaped (a
# container's first process may not reap what it adopts); given ten
# seconds, as a process still ending its agents is not yet either.
gone() {
    for _ in $(seq 1 50); do
        if ! kill -0 "$1" 2>/dev/null || [ "$(sed 's/.*) //' /proc/"$1"/stat 2>/dev/null | cut -c1)" = Z ]; then return 0; fi
        sleep 0.2
    done
    return 1
}

PW="$($BIN password)"
check test ${#PW} -ge 12

# In the terminal, stopped through the REST side.
$BIN run --port $PORT > /tmp/visor-server-run.log 2>&1 &
sleep 2
export VISOR_PORT=$PORT VISOR_TOKEN="$PW"
check env QUIT=1 node tools/probes/server.mjs
sleep 1
check grep -q "session started: probe-server" /tmp/visor-server-run.log

# In the background: started, restarted, its program replaced and restarted again, stopped. From a
# copy, which the probe replaces: once the file a process was started from is replaced, Linux names
# its program "<path> (deleted)", and a successor started from that name never ran.
COPY="$(mktemp -d)"
cp "$BIN" "$COPY/visor-server"
if [ -x "$(dirname "$BIN")/visor-agent-host" ]; then cp "$(dirname "$BIN")/visor-agent-host" "$COPY/"; fi
BIN="$COPY/visor-server"
check $BIN start --port $PORT
sleep 2
check $BIN status
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/visor"
restart() {
    curl -s -X POST -H "Authorization: Bearer $PW" http://127.0.0.1:$PORT/api/restart -d '{}' > /dev/null
    sleep 4
}
FIRST=$(cut -d' ' -f1 "$DATA/visor-server.pid")
restart
check gone "$FIRST"
check node tools/probes/server.mjs
# The successor's id once it has answered: the pid file can name the one
# starting it a moment before.
SECOND=$(cut -d' ' -f1 "$DATA/visor-server.pid")
check test "$FIRST" != "$SECOND"
cp "$BIN" "$BIN.new" && mv "$BIN.new" "$BIN"
restart
check gone "$SECOND"
check node tools/probes/server.mjs
THIRD=$(cut -d' ' -f1 "$DATA/visor-server.pid")
check test "$SECOND" != "$THIRD"
check $BIN stop
check gone "$THIRD"
rm -rf "$COPY"
echo "--- the background server's log"
cat "$DATA/visor-server.log"
echo "failures $failures"
exit $failures
