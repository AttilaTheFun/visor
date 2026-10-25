#!/bin/bash
# The iOS probe's cases that need no computer (the snapshot fixture), in the
# simulator, judged by what the tests say. xcodebuild's teardown took minutes
# after the tests had finished, gathering the simulator's diagnostics (none
# are gathered now: -collect-test-diagnostics never), which Bazel reported as
# a timeout; once the tests have said how they went, xcodebuild is given a
# while to write its result bundle, then stopped. CI runs this, in
# each orientation, and keeps what it made for review; so can a VM, or any
# Mac with Xcode.
#
#   tools/ios_ui_tests.sh
#   VISOR_UI_CASES=VisorProbe/testSiteShots tools/ios_ui_tests.sh   # other cases
#   VISOR_PROBE_ORIENTATION=landscape tools/ios_ui_tests.sh          # on their side
#
# Each case is recorded (XCTest's screen recording) and its pictures kept,
# in the result bundle bazel-testlogs/tests/ios_probe/visor_probe/
# test.outputs/tests.xcresult; the fixture's screens (testFixtureScreens,
# testFixtureScreensLandscape) also in /private/tmp/visor_probe.
set -uo pipefail
cd "$(dirname "$0")/.."
CASES="${VISOR_UI_CASES:-VisorProbe/testLearningOfEarlierRowsMovesNothing,VisorProbe/testRowsArrivingWhileReadingAboveMoveNothing,VisorProbe/testScrollingUpWhileARowPoursInIsNotFought,VisorProbe/testRowsArrivingAtTheEndAreScrolledTo,VisorProbe/testRefusingDictationLeavesTheAppRunning,VisorProbe/testFixtureSlashCommands,VisorProbe/testFixtureQuestion,VisorProbe/testABurstOfRowsAtTheEndIsFollowedToItsEnd,VisorProbe/testTypingThroughAnAutocorrectionKeepsTheCaret}"
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
  # No keyboard suggestions over the keys: what they say is learned and
  # comes in late, a picture's noise ("and disc is" one run, nothing the
  # next). Autocorrection stays: a case types through one.
  xcrun simctl spawn "$SIM" defaults write com.apple.Preferences KeyboardPrediction -bool NO
fi
bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64 \
  --ios_simulator_device="iPhone 17" --ios_simulator_version=27.0 \
  --test_env=VISOR_PROBE_ORIENTATION="${VISOR_PROBE_ORIENTATION:-portrait}" \
  --test_arg=--xctestrun_attachment_lifetime=keepAlways --test_arg=--xctestrun_screen_capture_format=screenRecording \
  --test_arg=--xcodebuild_args=-collect-test-diagnostics --test_arg=--xcodebuild_args=never \
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
pkill -f "xcodebuild.*visor_probe" 2>/dev/null
kill "$BAZEL" 2>/dev/null
wait "$BAZEL" 2>/dev/null
cat "$LOG"
# Passed only if no case failed: xcodebuild runs the cases in batches, each
# its own "Selected tests", and a later batch's pass hid an earlier failure.
if grep -q "Test Suite 'Selected tests' passed" "$LOG" && ! grep -q "^Test Case '.*' failed" "$LOG"; then
  echo "iOS UI tests passed"
else
  echo "iOS UI tests failed (or never ran)" >&2
  exit 1
fi
