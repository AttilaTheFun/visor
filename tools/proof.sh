#!/bin/bash
# The proof of a commit, made on this Mac or a test VM instead of in CI
# (Logan, 19 Oct: "run the fast tests and builds on ci but the snapshot
# and other verification proof locally"): what CI's ios-ui and mac-screens
# jobs made, in the same folders, for an agent to publish to the review
# server tagged with the commit (releases: //reviews/harnesses:publish_proof).
#
#   tools/proof.sh                 -> .proof/ (or $PROOF_DIR)
#     ios-portrait/, ios-landscape/  the fixture's screens (screens/fixture-*.png) and the UI cases, each
#                                    recorded (tests.xcresult), on the iPhone 17 simulator with iOS 27
#     mac-screenshots/               the Mac client's screens, only with PROOF_MAC=1: they draw a window
#                                    and make it key, so only on a test VM, never on a Mac someone uses
#
# Exits 1 when a case failed (the proof is kept all the same: it shows
# what failed).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${PROOF_DIR:-$PWD/.proof}"
rm -rf "$OUT"
mkdir -p "$OUT"
# The simulator as CI's was: iPhone 17, iOS 27, the status bar at 9:41,
# and new (erased): another app's tests on it leave their state, such as a
# permission prompt over every screen.
runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-0' | head -1)"
id="$(xcrun simctl list devices | grep -F "BAZEL_TEST_iPhone 17_27.0 (" | grep -o '[0-9A-F-]\{36\}' | head -1)"
[ -n "$id" ] || id="$(xcrun simctl create "BAZEL_TEST_iPhone 17_27.0" "iPhone 17" "$runtime")"
xcrun simctl shutdown "$id" 2>/dev/null || true
xcrun simctl erase "$id"
xcrun simctl boot "$id" 2>/dev/null || true
xcrun simctl bootstatus "$id" >/dev/null
xcrun simctl status_bar "$id" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
status=0
for orientation in portrait landscape; do
  kept="$OUT/ios-$orientation"
  mkdir -p "$kept/screens"
  rm -rf /private/tmp/visor_probe
  case "$orientation" in landscape) screens=testFixtureScreensLandscape ;; *) screens=testFixtureScreens ;; esac
  VISOR_UI_CASES="VisorProbe/$screens" tools/ios_ui_tests.sh > "$kept/screens.log" 2>&1 || status=1
  VISOR_PROBE_ORIENTATION="$orientation" tools/ios_ui_tests.sh > "$kept/ui-tests.log" 2>&1 || status=1
  cp /private/tmp/visor_probe/fixture-*.png "$kept/screens/" 2>/dev/null || true
  cp -R bazel-testlogs/tests/ios_probe/visor_probe/test.outputs/tests.xcresult "$kept/" 2>/dev/null || true
  # Bazel's outputs are read-only, and xcresulttool writes as it reads.
  chmod -R u+w "$kept" 2>/dev/null || true
  echo "ios-$orientation: $(ls "$kept/screens" | wc -l | tr -d ' ') screens, $(grep -c "^Test Case '.*' passed" "$kept/ui-tests.log") cases passed, $(grep -c "^Test Case '.*' failed" "$kept/ui-tests.log") failed"
done
if [ "${PROOF_MAC:-0}" = 1 ]; then
  mkdir -p "$OUT/mac-screenshots"
  bazel build //tools/mac_screenshots >/dev/null 2>&1 || status=1
  tool="$(bazel cquery --output=files //tools/mac_screenshots 2>/dev/null | head -1)"
  for screen in chat question models inspector new-session; do
    "$tool" "$screen" "$OUT/mac-screenshots/mac-$screen.png" dark || status=1
  done
else
  echo "mac-screenshots: not made (PROOF_MAC=1, on a test VM)"
fi
echo "The proof of $(git rev-parse --short HEAD) is in $OUT"
exit $status
