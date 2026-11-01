#!/bin/bash
# Records the simulator while the app comes back to a thread that moved on
# without it: the iOS probe opens a throwaway session, sends a turn that
# writes many rows (a tool call each), leaves the app at once, and comes
# back once the turn is done, the thread behind by all of it. The frames
# after the return are laid out as contact sheets to look at: the rows
# caught up on must not be seen arriving page by page.
#
#   tools/probes/frames/return_frames.sh [calls] [seconds away]   (default 80 calls, 150 s)
#
# Needs what send_motion.sh needs: the server running on this Mac, and the
# probe's simulator ("BAZEL_TEST_iPhone 17_27.2") booted. The session is a
# throwaway, started over the API and ended afterwards.
set -euo pipefail
cd "$(dirname "$0")/../../.."
HERE=tools/probes/frames
CALLS="${1:-80}"
AWAY="${2:-150}"
OUT="$(mktemp -d)/return"
mkdir -p "$OUT"
API=http://127.0.0.1:7433/api
PW="${VISOR_TOKEN:-$(security find-generic-password -s com.LoganShire.VisorServer.macOS -a password -w 2>/dev/null || true)}"
CODE_TEXT="${VISOR_PROBE_CODE:-$(curl -s -H "Authorization: Bearer $PW" $API/code | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')}"
HOST="$(python3 -c 'import json,sys,base64; t=sys.argv[1]; t+="="*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t))["host"])' "$CODE_TEXT")"
SIM_NAME="BAZEL_TEST_iPhone 17_27.2"
SIM="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -o '[0-9A-F-]\{36\}' | head -1)"
[ -n "$SIM" ] || { echo "No simulator named $SIM_NAME: run an iOS probe once to make it" >&2; exit 2; }
xcrun simctl list devices booted | grep -qF "$SIM" || { echo "$SIM_NAME is not booted: boot it with xcrun simctl boot $SIM" >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swiftc -O -o "$OUT/sheet" $HERE/sheet.swift
bazel build //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 2>&1 | grep -E "error:|Build completed" || true

# A throwaway session, with a first short turn so it has a thread.
WORK="$(mktemp -d)"
call() { curl -s -H "Authorization: Bearer $PW" -H 'Content-Type: application/json' "$@"; }
SESSION="$(call -X POST $API/sessions -d "{\"type\":\"start\",\"agent\":\"claude\",\"cwd\":\"$WORK\",\"title\":\"Return probe\",\"skipPermissions\":true,\"model\":\"${VISOR_FRAMES_MODEL:-haiku}\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"][0]["id"])')"
trap 'call -X DELETE $API/sessions/$SESSION >/dev/null; pkill -INT -f recordVideo 2>/dev/null || true' EXIT
call -X POST $API/sessions/$SESSION/send -d '{"type":"send","text":"Reply with the word ready."}' >/dev/null
for _ in $(seq 1 30); do
  sleep 2
  [ "$(call $API/sessions | python3 -c "import json,sys; print([s.get('busy') for s in json.load(sys.stdin)['sessions'] if s['id']=='$SESSION'][0])")" = "False" ] && break
done

TEXT="This is a test of how a long run of tool calls is shown. Do not use a loop or put two commands in one call: make $CALLS separate Bash tool calls, the first running echo 1, the next echo 2, and so on up to echo $CALLS, one command per call, in batches of up to ten calls at a time, with no text between them. Then reply with the word done."
python3 -c 'import time; print(time.time())' > "$OUT/rec-start"
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT/return.mov" > "$OUT/rec.log" 2>&1 &
REC=$!
bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 \
  --ios_simulator_device="iPhone 17" --ios_simulator_version=27.2 \
  --spawn_strategy=local --nocache_test_results --test_output=streamed --test_timeout=900 \
  --test_filter=VisorProbe/testSendFrames --test_env=VISOR_FRAMES_SESSION=$SESSION --test_env=VISOR_FRAMES_AWAY_AFTER_SEND=$AWAY \
  "--test_env=VISOR_FRAMES_TEXT=$TEXT" --test_env=VISOR_PROBE_HOST=$HOST "--test_env=VISOR_PROBE_CODE=$CODE_TEXT" > "$OUT/test.txt" 2>&1 &
TEST=$!
for _ in $(seq 1 900); do grep -q "VISOR_FRAMES end\|FAILED\|error:" "$OUT/test.txt" && break; sleep 1; done
sleep 1; kill -INT $REC; sleep 3
kill $TEST 2>/dev/null || true; pkill -f "xcodebuild.*visor_probe" 2>/dev/null || true
grep -q "VISOR_FRAMES end" "$OUT/test.txt" || { echo "The probe did not finish: $OUT/test.txt" >&2; exit 2; }
echo "rows on the computer: $(call $API/sessions/$SESSION/transcript | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("entries") or []))') (the latest served)"

# When the app came back, in the recording's time.
BACK="$(python3 - "$OUT" <<'PY'
import datetime, re, sys
out = sys.argv[1]
start = datetime.datetime.fromtimestamp(float(open(out + "/rec-start").read()))
for line in open(out + "/test.txt"):
    m = re.search(r"(\d\d):(\d\d):(\d\d\.\d+).*VISOR_FRAMES back", line)
    if m:
        at = start.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=int(float(m.group(3))), microsecond=int(float(m.group(3)) % 1 * 1e6))
        print(round((at - start).total_seconds(), 2))
        break
PY
)"
# Ten seconds after the return, five frames a second.
"$OUT/sheet" "$OUT/return.mov" "$BACK" "$(python3 -c "print($BACK + 10)")" 5 "$OUT/frames" 5 4 >/dev/null
echo "Back at ${BACK}s; frames in $OUT (frames-*.png): the thread must not step through the rows caught up on."
