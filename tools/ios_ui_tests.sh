#!/bin/bash
# The iOS probe's cases that need no computer (the snapshot fixture), in the
# simulator, judged by what the tests say: xcodebuild's teardown can hang
# long after they have finished, which Bazel then reports as a timeout. Once
# the tests have said how they went, xcodebuild is stopped. CI runs this.
#
#   tools/ios_ui_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CASES="VisorProbe/testLearningOfEarlierRowsMovesNothing"
LOG="$(mktemp)"
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
