#!/bin/bash
# The iOS probe's fixture cases on a phone, as tools/ios_ui_tests.sh runs
# them in the simulator: the probe's device host (tests/ios_probe:probe_host,
# the app signed with the team's wildcard profile, which the device must be
# in; tools/mint_profile adds it), judged by what the tests say. Run in a
# lease of the lab's iPhone, which sets DEVICE_LAB_UDID:
#
#   device-lab run --device iphone-xs -- tools/ios_device_tests.sh
#   VISOR_UI_CASES=VisorProbe/testFixtureQuestion tools/ios_device_tests.sh   # other cases
#
# HOME is passed on: the runner signs its app with the login keychain's
# identity, which a test's own HOME does not reach.
#
# VISOR_PROBE_ORIENTATION=landscape holds the cases on their side. Each case
# is recorded (XCTest's screen recording) and its pictures kept, in the
# result bundle bazel-testlogs/tests/ios_probe/visor_probe_device/
# test.outputs/tests.xcresult (release_review's harness reads it back).
set -uo pipefail
cd "$(dirname "$0")/.."
UDID="${DEVICE_LAB_UDID:?run in a device-lab lease of the phone, or set DEVICE_LAB_UDID}"
CASES="${VISOR_UI_CASES:-VisorProbe/testLearningOfEarlierRowsMovesNothing,VisorProbe/testRowsArrivingWhileReadingAboveMoveNothing,VisorProbe/testRowsArrivingAtTheEndAreScrolledTo,VisorProbe/testRefusingDictationLeavesTheAppRunning,VisorProbe/testFixtureSlashCommands,VisorProbe/testFixtureQuestion,VisorProbe/testABurstOfRowsAtTheEndIsFollowedToItsEnd}"
LOG="$(mktemp)"
bazel test //tests/ios_probe:visor_probe_device --ios_multi_cpus=arm64 \
  --test_arg=--destination=platform=iOS,id="$UDID" --test_env=HOME="$HOME" \
  --test_env=VISOR_PROBE_ORIENTATION="${VISOR_PROBE_ORIENTATION:-portrait}" \
  --test_arg=--xctestrun_attachment_lifetime=keepAlways --test_arg=--xctestrun_screen_capture_format=screenRecording \
  --nozip_undeclared_test_outputs \
  --spawn_strategy=local --nocache_test_results --test_output=streamed \
  --test_filter="$CASES" > "$LOG" 2>&1 &
BAZEL=$!
while kill -0 "$BAZEL" 2>/dev/null; do
  grep -q "Test Suite 'Selected tests' \(passed\|failed\)" "$LOG" && break
  sleep 5
done
# The result bundle written after the verdict (its recordings take a
# while), then the hang, if there is one, cut short.
for _ in $(seq 1 60); do kill -0 "$BAZEL" 2>/dev/null || break; sleep 3; done
pkill -f "xcodebuild.*visor_probe_device" 2>/dev/null
kill "$BAZEL" 2>/dev/null
wait "$BAZEL" 2>/dev/null
cat "$LOG"
if grep -q "Test Suite 'Selected tests' passed" "$LOG"; then
  echo "iOS UI tests passed on the phone"
else
  echo "iOS UI tests failed on the phone (or never ran)" >&2
  exit 1
fi
