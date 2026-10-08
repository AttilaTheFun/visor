#!/bin/bash
# Records the simulator while the iOS probe opens a session for the first
# time (an erased simulator: nothing cached, the rows come from the first
# sync), and lays the frames around the tap out as contact sheets to look
# at. The thread must appear once, at its end: rows laid out from the top
# and scrolled a frame later show the thread's top for that frame — the
# flicker this exists to catch. (A pixel measure of it would be fooled by
# the push animation under way at the same moment, so this is a look, not
# a gate: the sheets are what to check.)
#
#   tools/probes/frames/open_frames.sh <session id>
#
# Needs: the server running on this Mac (the session may be any of its
# own, opened and read only) and the probe's simulator ("BAZEL_TEST_iPhone
# 17_27.0"), which is erased, booted and signed in with the connection
# code. Ends with the sheets' folder.
set -euo pipefail
cd "$(dirname "$0")/../../.."
HERE=tools/probes/frames
SESSION="${1:?session id}"
OUT="$(mktemp -d)/open"
mkdir -p "$OUT"
API=http://127.0.0.1:7433/api
PW="${VISOR_TOKEN:-$(security find-generic-password -s com.LoganShire.VisorServer.macOS -a password -w 2>/dev/null || true)}"
CODE_TEXT="$(curl -s -H "Authorization: Bearer $PW" $API/code | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')"
HOST="$(python3 -c 'import json,sys,base64; t=sys.argv[1]; t+="="*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t))["host"])' "$CODE_TEXT")"
SIM_NAME="BAZEL_TEST_iPhone 17_27.0"
SIM="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -o '[0-9A-F-]\{36\}' | head -1)"
[ -n "$SIM" ] || { echo "No simulator named $SIM_NAME: run an iOS probe once to make it" >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swiftc -O -o "$OUT/sheet" $HERE/sheet.swift
xcrun simctl shutdown "$SIM" 2>/dev/null || true
xcrun simctl erase "$SIM"
xcrun simctl boot "$SIM"
xcrun simctl bootstatus "$SIM" >/dev/null
cleanup() { pkill -INT -f "simctl io $SIM recordVideo" 2>/dev/null || true; }
trap cleanup EXIT
python3 -c 'import time; print(time.time())' > "$OUT/rec-start"
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT/open.mov" > "$OUT/rec.log" 2>&1 &
REC=$!
bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 \
  --ios_simulator_device="iPhone 17" --ios_simulator_version=27.0 \
  --spawn_strategy=local --nocache_test_results --test_output=streamed \
  --test_filter=VisorProbe/testSelectSession --test_env=VISOR_SELECT_SESSION=$SESSION \
  --test_env=VISOR_PROBE_HOST=$HOST "--test_env=VISOR_PROBE_CODE=$CODE_TEXT" > "$OUT/test.txt" 2>&1 &
TEST=$!
for _ in $(seq 1 600); do grep -q "VISOR_SELECT end\|FAILED\|error:" "$OUT/test.txt" && break; sleep 1; done
sleep 1; kill -INT $REC; sleep 3
kill $TEST 2>/dev/null || true; pkill -f "xcodebuild.*visor_probe" 2>/dev/null || true
grep -q "VISOR_SELECT end" "$OUT/test.txt" || { echo "The probe did not finish: $OUT/test.txt" >&2; exit 2; }
TAP="$(python3 - "$OUT" <<'PY'
import datetime, re, sys
out = sys.argv[1]
start = datetime.datetime.fromtimestamp(float(open(out + "/rec-start").read()))
for line in open(out + "/test.txt"):
    m = re.search(r"(\d\d):(\d\d):(\d\d\.\d+).*VISOR_SELECT tap", line)
    if m:
        at = start.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=int(float(m.group(3))), microsecond=int(float(m.group(3)) % 1 * 1e6))
        print(round((at - start).total_seconds(), 2))
        break
PY
)"
"$OUT/sheet" "$OUT/open.mov" "$(python3 -c "print($TAP - 0.1)")" "$(python3 -c "print($TAP + 1.4)")" 30 "$OUT/frames" 6 3 >/dev/null
echo "Opened at ${TAP}s; frames in $OUT (frames-*.png): the thread must appear once, at its end."
