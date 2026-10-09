#!/bin/bash
# Checks that sending a message does not make the thread jump: records the
# simulator while the iOS probe types a message of several lines into a
# throwaway session and sends it, then measures how the thread moved in the
# frames around the send (motion.swift). Fails when the thread steps down —
# what it does when the composer gives up its lines a frame before the
# message goes into the thread, or the sent row is dropped and put back.
#
#   tools/probes/frames/send_motion.sh [host]     (default: this Mac's address)
#
# VISOR_FRAMES_MODEL (default haiku) and VISOR_FRAMES_TEXT give a turn of
# another shape (thinking, tool calls); VISOR_FRAMES_AFTER, the seconds
# measured after the send (default 1.6; the probe stays 20 s), to take in
# the rows that arrive later in the turn. VISOR_FRAMES_READ=1 sends from
# up the thread (the keyboard up), as after reading a long reply.
#
# Needs: the server running on this Mac and a booted simulator the probe
# runs on (rules_apple's "BAZEL_TEST_iPhone 17_27.0"; boot it with `xcrun
# simctl boot`). Its Visor is signed in to this computer if it is not yet. The session is a throwaway,
# started over the API and ended afterwards. Contact sheets of the frames are
# left in the output folder for a look (sheet.swift).
set -euo pipefail
cd "$(dirname "$0")/../../.."
HERE=tools/probes/frames
OUT="$(mktemp -d)/send"
mkdir -p "$OUT"
API=http://127.0.0.1:7433/api
PW="${VISOR_TOKEN:-$(security find-generic-password -s com.LoganShire.VisorServer.macOS -a password -w 2>/dev/null || true)}"
# The connection code, which the probe signs in with should the
# simulator's Visor not know this computer yet (an erased simulator): it
# carries the password, and is never printed.
# (VISOR_PROBE_CODE, set, is the code to sign in with instead: a path of
# another shape, such as a relay through a second server, which polls.)
CODE_TEXT="${VISOR_PROBE_CODE:-$(curl -s -H "Authorization: Bearer $PW" $API/code | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')}"
HOST="${1:-$(python3 -c 'import json,sys,base64; t=sys.argv[1]; t+="="*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t))["host"])' "$CODE_TEXT")}"
# Only the test runner's own simulator, by name: whatever else is booted
# may be another agent's (one simulator per agent at a time).
SIM_NAME="BAZEL_TEST_iPhone 17_27.0"
SIM="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -o '[0-9A-F-]\{36\}' | head -1)"
[ -n "$SIM" ] || { echo "No simulator named $SIM_NAME: run an iOS probe once to make it" >&2; exit 2; }
xcrun simctl list devices booted | grep -qF "$SIM" || { echo "$SIM_NAME is not booted: boot it with xcrun simctl boot $SIM" >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swiftc -O -o "$OUT/motion" $HERE/motion.swift
swiftc -O -o "$OUT/sheet" $HERE/sheet.swift
bazel build //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 2>&1 | grep -E "error:|Build completed" || true

# A throwaway session with a thread long enough to scroll.
WORK="$(mktemp -d)"
call() { curl -s -H "Authorization: Bearer $PW" -H 'Content-Type: application/json' "$@"; }
SESSION="$(call -X POST $API/sessions -d "{\"type\":\"start\",\"agent\":\"claude\",\"cwd\":\"$WORK\",\"title\":\"Send probe\",\"skipPermissions\":true,\"model\":\"${VISOR_FRAMES_MODEL:-haiku}\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"][0]["id"])')"
trap 'call -X DELETE $API/sessions/$SESSION >/dev/null; pkill -INT -f recordVideo 2>/dev/null || true' EXIT
call -X POST $API/sessions/$SESSION/send -d '{"type":"send","text":"Print the numbers 1 to 60, each on its own line, then two short paragraphs about bananas. No tools."}' >/dev/null
for _ in $(seq 1 60); do
  sleep 2
  [ "$(call $API/sessions | python3 -c "import json,sys; print([s.get('busy') for s in json.load(sys.stdin)['sessions'] if s['id']=='$SESSION'][0])")" = "False" ] && break
done

TEXT="${VISOR_FRAMES_TEXT:-Thanks for that. Now I would like you to reply with exactly the word banana and nothing else at all, please. This message is deliberately long so that it wraps over several lines in the composer on a phone, the way a real message does when it describes a bug in detail.}"
python3 -c 'import time; print(time.time())' > "$OUT/rec-start"
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT/send.mov" > "$OUT/rec.log" 2>&1 &
REC=$!
bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 \
  --ios_simulator_device="iPhone 17" --ios_simulator_version=27.0 \
  --spawn_strategy=local --nocache_test_results --test_output=streamed \
  --test_filter=VisorProbe/testSendFrames --test_env=VISOR_FRAMES_SESSION=$SESSION --test_env=VISOR_FRAMES_READ=${VISOR_FRAMES_READ:-0} \
  "--test_env=VISOR_FRAMES_TEXT=$TEXT" --test_env=VISOR_PROBE_HOST=$HOST "--test_env=VISOR_PROBE_CODE=$CODE_TEXT" > "$OUT/test.txt" 2>&1 &
TEST=$!
for _ in $(seq 1 600); do grep -q "VISOR_FRAMES end\|FAILED\|error:" "$OUT/test.txt" && break; sleep 1; done
sleep 1; kill -INT $REC; sleep 3
# (xcodebuild's own teardown takes minutes: not waited for.)
kill $TEST 2>/dev/null || true; pkill -f "xcodebuild.*visor_probe" 2>/dev/null || true
grep -q "VISOR_FRAMES end" "$OUT/test.txt" || { echo "The probe did not finish: $OUT/test.txt" >&2; exit 2; }

# When the probe tapped Send, in the recording's time.
SEND="$(python3 - "$OUT" <<'PY'
import datetime, re, sys
out = sys.argv[1]
start = datetime.datetime.fromtimestamp(float(open(out + "/rec-start").read()))
for line in open(out + "/test.txt"):
    m = re.search(r"(\d\d):(\d\d):(\d\d\.\d+).*VISOR_FRAMES send", line)
    if m:
        at = start.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=int(float(m.group(3))), microsecond=int(float(m.group(3)) % 1 * 1e6))
        print(round((at - start).total_seconds(), 2))
        break
PY
)"
"$OUT/sheet" "$OUT/send.mov" "$(python3 -c "print($SEND - 0.1)")" "$(python3 -c "print($SEND + 1.1)")" 30 "$OUT/frames" 9 2 >/dev/null
echo "Send at ${SEND}s; frames in $OUT"
"$OUT/motion" "$OUT/send.mov" "$(python3 -c "print($SEND - 0.2)")" "$(python3 -c "print($SEND + ${VISOR_FRAMES_AFTER:-1.6})")"
