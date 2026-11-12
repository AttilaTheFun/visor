#!/bin/bash
# The iPhone's part of the proof (ci.yml's verify), in one orientation, on
# one of GitHub's own Macs (`xcode-27`): the app, built on Linux by the
# proof's build job for Apple silicon's simulator, on an iPhone 17 of iOS
# 27.2 (the runtime the pictures it is compared with were taken on: GitHub
# rolls a new image out over days, and its runners' older one had iOS 27.0
# alone, whose pictures differ in most screens; downloaded where the image
# hasn't got it), made for the run, its status bar held still and keyboard
# suggestions off. Each of the fixture's screens is opened as Isomer's proof
# opens a story: the app launched on it (`simctl launch`, the fixture's
# arguments), pictured with the screen's cut-outs masked once two pictures
# in a row are the same. No XCUITest: its launches are what made the proof
# slow and, on a slow runner, flaky (12 Nov 2026).
#
# On its side, the app turns itself (`-visor.fixture.orientation landscape`:
# its delegate allows landscape alone), as the simulator has no command to
# turn the device; its picture, the device's upright frame, is turned to
# stand as the screen is read.
#
#   tools/ci/proof_ios.sh <apps> <out> [portrait|landscape]
#
# <apps> holds visor_ios.ipa. Out come <out>/screens/ios-<screen>.png (on
# its side, ios-<screen>-landscape.png), <out>/logs/ (each launch's output)
# and <out>/device.txt (the simulator and Xcode, for the proof's summary).
#
#   DEVELOPER_DIR       the Xcode (default: Xcode 27.2, the SDK the apps are
#                       built with, where the image has it; else its default)
#   PROOF_IOS_VERSION   the simulator's iOS (default: 27.2)
#   VISOR_SNAPSHOT_SETTLE  seconds a screen is given before its first
#                       picture (default 4; the search's, 20: its matches in
#                       messages come later)
#
# Fails when a screen has no picture, after every screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_ios.sh <apps> <out> [portrait|landscape]" >&2; exit 2; }
[ $# -ge 2 ] || usage
apps="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
orientation="${3:-portrait}"
case "$orientation" in portrait | landscape) ;; *) usage ;; esac
DEVICE="iPhone 17"
BUNDLE_ID="com.LoganShire.Visor"
SETTLE="${VISOR_SNAPSHOT_SETTLE:-4}"
# The fixture's screens, as the probe pictured them (tests/ios_probe's
# fixtureShots): their ids are the proof's, kept from release to release.
SCREENS="sessions machines chat question goal inspector models search connect runner runner-accounts new-session commands"
[ -f "$apps/visor_ios.ipa" ] || { echo "$me: no visor_ios.ipa in $apps" >&2; exit 1; }
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi

work="$(mktemp -d)"
udid=""
finished=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" 2> /dev/null || true
        xcrun simctl delete "$udid" 2> /dev/null || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$out/screens" "$out/logs"

echo "::group::An $DEVICE"
# The runtime of that iOS that runs the device (a runtime that came with a
# new phone runs that phone alone: xcode-27's iOS 27.1, the iPhone Duo; its
# iOS 27.2 has one for the iPhone 19 beside the one for the rest).
IOS_VERSION="${PROOF_IOS_VERSION:-27.2}"
pick_runtime() {
    xcrun simctl list runtimes --json | python3 -I -c '
import json, sys
device, version = sys.argv[1:3]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")
            and (r["version"] == version or r["version"].startswith(version + "."))
            and any(t.get("name") == device for t in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(runtimes[-1]["identifier"] + " " + runtimes[-1]["version"] + " (" + runtimes[-1].get("buildversion", "?") + ")" if runtimes else "")' "$DEVICE" "$IOS_VERSION"
}
runtime="$(pick_runtime)"
if [ -z "$runtime" ]; then
    echo "::warning::This image has no iOS $IOS_VERSION simulator that runs an $DEVICE: downloading it"
    xcodebuild -downloadPlatform iOS -buildVersion "$IOS_VERSION" > "$out/logs/download-platform.log" 2>&1 \
        || tail -20 "$out/logs/download-platform.log"
    # Listed a little after it is installed, once CoreSimulator has mounted it.
    for _ in $(seq 1 24); do
        runtime="$(pick_runtime)"
        [ -z "$runtime" ] || break
        sleep 5
    done
fi
[ -n "$runtime" ] || { echo "::error::No iOS $IOS_VERSION simulator that runs an $DEVICE on this runner: its pictures would not compare with the base's"; exit 1; }
version="${runtime#* }"
runtime="${runtime%% *}"
udid="$(xcrun simctl create "Visor proof" "$DEVICE" "$runtime")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b > /dev/null
# The status bar as Shireworks holds a lease's: 9:41 on a fixed day (an
# older simctl takes the time alone), full Wi-Fi and signal, a full
# battery, no carrier. No keyboard suggestions over the keys: what they say
# is learned and comes in late. The light look, whatever the image's.
bar=(--dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4
     --operatorName "" --batteryState charged --batteryLevel 100)
still="$(python3 -I -c 'import datetime; print(datetime.datetime(2007, 1, 9, 9, 41).astimezone().isoformat(timespec="milliseconds"))')"
xcrun simctl status_bar "$udid" override --time "$still" "${bar[@]}" 2> /dev/null \
    || xcrun simctl status_bar "$udid" override --time 9:41 "${bar[@]}"
xcrun simctl spawn "$udid" defaults write com.apple.Preferences KeyboardPrediction -bool NO
xcrun simctl ui "$udid" appearance light 2> /dev/null || true
ditto -x -k "$apps/visor_ios.ipa" "$work/ipa"
app="$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "$me: no app in visor_ios.ipa's Payload" >&2; exit 1; }
xcrun simctl install "$udid" "$app"
xcode="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
printf '%s, iOS %s, %s\n' "$DEVICE" "$version" "$xcode" | tee "$out/device.txt"
echo "::endgroup::"

# A picture of the screen as it is, upright: the simulator's frame is the
# device's, upright whichever way the app is turned, so one of the app on
# its side is turned a quarter anticlockwise (the app takes landscapeRight,
# as the probe's device turned to landscapeLeft did).
picture() {
    xcrun simctl io "$udid" screenshot --type=png --mask=black "$1" > /dev/null 2>&1 || return 1
    if [ "$orientation" = landscape ]; then
        python3 -I - "$1" << 'PY'
import struct, subprocess, sys
with open(sys.argv[1], "rb") as f:
    width, height = struct.unpack(">II", f.read(24)[16:24])
if width < height:
    subprocess.run(["sips", "-r", "270", sys.argv[1]], check=True, stdout=subprocess.DEVNULL)
PY
    fi
}

echo "::group::The screens ($orientation)"
status=0
arguments=(-visor.fixture snapshot)
suffix=""
if [ "$orientation" = landscape ]; then
    arguments+=(-visor.fixture.orientation landscape)
    suffix="-landscape"
fi
for screen in $SCREENS; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
    if ! xcrun simctl launch "$udid" "$BUNDLE_ID" "${arguments[@]}" -visor.fixture.screen "$screen" \
        > "$out/logs/$screen$suffix.log" 2>&1; then
        echo "::error::$screen did not launch"
        cat "$out/logs/$screen$suffix.log"
        status=1
        continue
    fi
    settle="$SETTLE"
    [ "$screen" != search ] || settle=20
    sleep "$settle"
    # Pictured until two in a row are the same (a second apart), at most
    # fifteen times: a caret's blink may keep any two from matching, and
    # then the last is kept.
    shot="$out/screens/ios-$screen$suffix.png"
    previous="$work/previous.png"
    rm -f "$previous" "$shot"
    steady=""
    for _ in $(seq 1 15); do
        picture "$shot" || { sleep 1; continue; }
        if [ -f "$previous" ] && cmp -s "$shot" "$previous"; then
            steady=1
            break
        fi
        cp "$shot" "$previous"
        sleep 1
    done
    if [ ! -s "$shot" ]; then
        echo "::error::no picture of $screen"
        rm -f "$shot"
        status=1
    elif [ -z "$steady" ]; then
        echo "$screen (never the same twice: the last picture kept)"
    else
        echo "$screen"
    fi
done
xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
echo "::endgroup::"
count="$(find "$out/screens" -name 'ios-*.png' | wc -l | tr -d ' ')"
echo "$count iPhone screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
