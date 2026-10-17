#!/bin/bash
# The iOS probe's cases that need no computer (the snapshot fixture), in the
# simulator, judged by what the tests say: xcodebuild's teardown can hang
# long after they have finished, which Bazel then reports as a timeout. Once
# the tests have said how they went, xcodebuild is stopped. CI runs this.
#
#   tools/ios_ui_tests.sh
#   VISOR_UI_CASES=VisorProbe/testSiteShots tools/ios_ui_tests.sh   # other cases
set -uo pipefail
cd "$(dirname "$0")/.."
CASES="${VISOR_UI_CASES:-VisorProbe/testLearningOfEarlierRowsMovesNothing,VisorProbe/testRowsArrivingWhileReadingAboveMoveNothing,VisorProbe/testRowsArrivingAtTheEndAreScrolledTo,VisorProbe/testRefusingDictationLeavesTheAppRunning,VisorProbe/testFixtureSlashCommands,VisorProbe/testFixtureQuestion}"
LOG="$(mktemp)"
# On the simulator the tests run on, when it exists already (CI's is new):
# the app taken off, since installing over a copy can leave its old binary,
# and the permission prompts undecided again (the dictation case answers
# one).
SIM="$(xcrun simctl list devices | grep -F "BAZEL_TEST_iPhone 17_27.0 (" | grep -o '[0-9A-F-]\{36\}' | head -1)"
if [ -n "$SIM" ]; then
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl uninstall "$SIM" com.LoganShire.VisorClient.iOS 2>/dev/null || true
  xcrun simctl privacy "$SIM" reset all com.LoganShire.VisorClient.iOS 2>/dev/null || true
fi
bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 \
  --ios_simulator_device="iPhone 17" --ios_simulator_version=27.0 \
  --spawn_strategy=local --nocache_test_results --test_output=streamed \
  --test_filter="$CASES" > "$LOG" 2>&1 &
BAZEL=$!
while kill -0 "$BAZEL" 2>/dev/null; do
  grep -q "Test Suite 'Selected tests' \(passed\|failed\)" "$LOG" && break
  sleep 5
done
# The lines after the verdict, then the hang, if there is one, cut short.
sleep 3
pkill -f "xcodebuild.*visor_probe" 2>/dev/null
kill "$BAZEL" 2>/dev/null
wait "$BAZEL" 2>/dev/null
cat "$LOG"
if grep -q "Test Suite 'Selected tests' passed" "$LOG"; then
  echo "iOS UI tests passed"
else
  echo "iOS UI tests failed (or never ran)" >&2
  exit 1
fi
