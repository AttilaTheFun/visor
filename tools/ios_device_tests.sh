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
set -uo pipefail
cd "$(dirname "$0")/.."
UDID="${DEVICE_LAB_UDID:?run in a device-lab lease of the phone, or set DEVICE_LAB_UDID}"
CASES="${VISOR_UI_CASES:-VisorProbe/testLearningOfEarlierRowsMovesNothing,VisorProbe/testRowsArrivingWhileReadingAboveMoveNothing,VisorProbe/testRowsArrivingAtTheEndAreScrolledTo,VisorProbe/testRefusingDictationLeavesTheAppRunning,VisorProbe/testFixtureSlashCommands,VisorProbe/testFixtureQuestion}"
LOG="$(mktemp)"
bazel test //tests/ios_probe:visor_probe_device --ios_multi_cpus=arm64 \
  --test_arg=--destination=platform=iOS,id="$UDID" --test_env=HOME="$HOME" \
  --spawn_strategy=local --nocache_test_results --test_output=streamed \
  --test_filter="$CASES" > "$LOG" 2>&1 &
BAZEL=$!
while kill -0 "$BAZEL" 2>/dev/null; do
  grep -q "Test Suite 'Selected tests' \(passed\|failed\)" "$LOG" && break
  sleep 5
done
# The lines after the verdict, then the hang, if there is one, cut short.
sleep 3
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
