#!/bin/bash
# Checks that the iOS app's fixture screens look as they did when right:
# each screen (the snapshot fixture, no computer needed) is photographed on
# the simulator and compared with its reference in tests/look/ios — the
# bars' soft edge, the glass composer, wrapped list items, pictures, the
# sheets. Then the `earlier` screen is recorded as a page of earlier rows
# goes in above its short thread: the list must come to rest on the rows it
# showed, showing the page's top for no more than a few frames on the way.
#
#   tools/probes/look/fixture_look.sh            compare
#   tools/probes/look/fixture_look.sh --accept   take the screens as the references
#
# Works with the Mac locked (simctl alone, no UI test). Runs on a simulator
# of its own ("Visor Look iPhone 17", made if missing), erased first so no
# earlier run's state shows, and shut down after: shut down any other
# simulator of yours first (one per agent). What differs is drawn red in
# the output folder.
set -euo pipefail
cd "$(dirname "$0")/../../.."
HERE=tools/probes/look
REFS=tests/look/ios
OUT="$(mktemp -d)/look"
mkdir -p "$OUT" "$REFS"
ACCEPT=0
[ "${1:-}" = "--accept" ] && ACCEPT=1
SIM_NAME="Visor Look iPhone 17"
SIM="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | grep -o '[0-9A-F-]\{36\}' | head -1 || true)"
[ -n "$SIM" ] || SIM="$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
xcrun simctl shutdown "$SIM" 2>/dev/null || true
xcrun simctl erase "$SIM"
xcrun simctl boot "$SIM"
xcrun simctl bootstatus "$SIM" >/dev/null
APP=com.LoganShire.VisorClient.iOS
cleanup() {
  pkill -INT -f "simctl io $SIM recordVideo" 2>/dev/null || true
  xcrun simctl shutdown "$SIM" 2>/dev/null || true
}
trap cleanup EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swiftc -O -parse-as-library -o "$OUT/look" $HERE/look.swift

bazel build //applications/visor_ios --ios_multi_cpus=sim_arm64 2>&1 | grep -E "error:|Build completed" || true
IPA="$(bazel cquery --ios_multi_cpus=sim_arm64 --output=files //applications/visor_ios 2>/dev/null | head -1)"
unzip -qo "$IPA" -d "$OUT/app"
xcrun simctl install "$SIM" "$OUT/app/Payload/visor_ios.app"
xcrun simctl status_bar "$SIM" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode notSupported --batteryState discharging --batteryLevel 100

launch() {
  xcrun simctl terminate "$SIM" $APP 2>/dev/null || true
  xcrun simctl launch "$SIM" $APP -visor.fixture snapshot -visor.fixture.screen "$1" >/dev/null
}
wait_for() { python3 -c "import time; time.sleep($1)"; }

FAILED=0
check() {
  local name="$1"
  "$OUT/look" shrink "$OUT/$name-full.png" "$OUT/$name.png" 402
  if [ $ACCEPT = 1 ]; then
    cp "$OUT/$name.png" "$REFS/$name.png"
    echo "$name: accepted"
  elif [ ! -f "$REFS/$name.png" ]; then
    echo "$name: no reference (run with --accept)"; FAILED=1
  elif result="$("$OUT/look" compare "$OUT/$name.png" "$REFS/$name.png" "$OUT/$name-diff.png")"; then
    echo "$name: $result"
  else
    echo "$name: $result — see $OUT/$name-diff.png"; FAILED=1
  fi
}

# Screens at rest: the sheets' glass takes longest to ease in.
for screen in sessions chat goal search inspector models; do
  launch "$screen"
  case "$screen" in inspector|models) wait_for 8 ;; *) wait_for 5 ;; esac
  xcrun simctl io "$SIM" screenshot "$OUT/$screen-full.png" >/dev/null 2>&1
  check "$screen"
done

# A page of earlier rows: recorded from launch; the page is asked for once
# the thread has settled (about 1.2 s) and comes half a second later.
xcrun simctl terminate "$SIM" $APP 2>/dev/null || true
xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT/earlier.mov" > "$OUT/rec.log" 2>&1 &
REC=$!
wait_for 1
launch earlier
wait_for 6
xcrun simctl io "$SIM" screenshot "$OUT/earlier-full.png" >/dev/null 2>&1
kill -INT $REC; wait $REC 2>/dev/null || true
check earlier
if [ $ACCEPT = 0 ]; then
  if result="$("$OUT/look" settle "$OUT/earlier.mov" 2.0 6.5 3)"; then echo "earlier, going in: $result"; else echo "earlier, going in: $result"; FAILED=1; fi
fi

echo "Screens in $OUT"
exit $FAILED
