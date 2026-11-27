#!/bin/bash
# The iPhone's part of the proof (ci.yml's verify), in one orientation, on
# a Mac (in CI a macOS VM that a Nimbus runner leases, tools/ci/mac_vm.sh,
# both orientations in turn): the app, built on a Nimbus runner
# by the proof's build job (build-apple) for Apple silicon's simulator with Isomer's driver in it
# (--config=drive: never a release's), on an iPhone 17 of iOS 27.2 (the
# runtime the pictures it is compared with were taken on: GitHub rolls a
# new image out over days, and its runners' older one had iOS 27.0 alone,
# whose pictures differ in most screens; downloaded where the image hasn't
# got it), made for the run, its status bar held still and keyboard
# suggestions off. The screens are pictured through Isomer's driver
# (//tests/feature_map_tests:feature_map_proof_ios, its
# proof/FeatureMapProof.swift): one launch of the fixture walking
# FEATURE_MAP.md to each screen it reaches, and a launch for each screen
# whose fixture differs; each pictured by Isomer's iOS launcher (simctl,
# masked) once the driver says the screen has settled and two pictures in a
# row are the same. The test is built here by Bazel while the simulator
# boots and the apps build.
#
# On its side, the app turns itself (its `fixture.orientation` setting: its
# delegate allows landscape alone), as the simulator has no command to
# turn the device; its picture, the device's upright frame, is turned to
# stand as the screen is read.
#
#   tools/ci/proof_ios.sh <apps> <out> [portrait|landscape]
#
# <apps> holds visor_ios.ipa (built with --config=drive). Out come
# <out>/screens/ios-<screen>.png (on its side, ios-<screen>-landscape.png),
# <out>/logs/ (the test's log and the launchers') and <out>/device.txt (the
# simulator and Xcode, for the proof's summary).
#
#   DEVELOPER_DIR       the Xcode (default: Xcode 27.2, the SDK the apps are
#                       built with, where the image has it; else its default)
#   PROOF_IOS_VERSION   the simulator's iOS (default: 27.2)
#   PROOF_BAZEL         the Bazel to build and run the test (default: bazel)
#   VISOR_PROOF_SETTLE_SECONDS
#                       how long the test gives a screen to hold still
#                       before its picture (its default, 5, if unset: a
#                       slower simulator's sheets and turns take longer)
#
# Fails when the test fails (a screen that never showed) or a screen has no
# picture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_ios.sh <apps> <out> [portrait|landscape]" >&2; exit 2; }
[ $# -ge 2 ] || usage
mkdir -p "$1" "$2"
apps="$(cd "$1" && pwd)"
out="$(cd "$2" && pwd)"
orientation="${3:-portrait}"
case "$orientation" in portrait | landscape) ;; *) usage ;; esac
DEVICE="iPhone 17"
BUNDLE_ID="com.LoganShire.Visor"
BAZEL="${PROOF_BAZEL:-bazel}"
TEST=//tests/feature_map_tests:feature_map_proof_ios
# The fixture's screens, as the probe pictured them (tests/ios_probe's
# fixtureShots): their ids are the proof's, kept from release to release.
SCREENS="sessions machines chat question goal inspector models search connect new-session commands"
# Not there yet with PROOF_APPS_ARTIFACT: waited for once the simulator is up.
[ -f "$apps/visor_ios.ipa" ] || [ -n "${PROOF_APPS_ARTIFACT:-}" ] || { echo "$me: no visor_ios.ipa in $apps" >&2; exit 1; }
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi

work="$(mktemp -d)"
udid=""
finished=""
builder=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$builder" ] || kill "$builder" 2> /dev/null || true
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" 2> /dev/null || true
        xcrun simctl delete "$udid" 2> /dev/null || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$out/screens" "$out/logs"
# The test, built while the simulator boots (Bazel's own server; the run
# below waits for it).
(cd "$ROOT" && "$BAZEL" build "$TEST" > "$out/logs/test-build.log" 2>&1) &
builder=$!

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
# The apps, once the simulator is up: a job that starts with its run boots
# while the build job builds (PROOF_APPS_ARTIFACT, from PROOF_APPS_JOB).
if [ ! -f "$apps/visor_ios.ipa" ]; then
    "$ROOT/tools/ci/await_artifact.sh" "$PROOF_APPS_ARTIFACT" "$apps" "${PROOF_APPS_JOB:-build-apple}"
fi
[ -f "$apps/visor_ios.ipa" ] || { echo "$me: no visor_ios.ipa in $apps" >&2; exit 1; }
# Unpacked with ditto on a Mac; with unzip in Nimbus' `ios` lease (Apple's
# simulator under Darling, agent-sim's simctl), which has no ditto.
if command -v ditto > /dev/null; then
    ditto -x -k "$apps/visor_ios.ipa" "$work/ipa"
else
    unzip -q "$apps/visor_ios.ipa" -d "$work/ipa"
fi
app="$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "$me: no app in visor_ios.ipa's Payload" >&2; exit 1; }
xcrun simctl install "$udid" "$app"
# What pictured it: Xcode's version on a Mac; agent-sim's on Linux.
if command -v xcodebuild > /dev/null; then
    xcode="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
else
    xcode="$(agent-sim --version 2> /dev/null || echo agent-sim), Linux"
fi
printf '%s, iOS %s, %s\n' "$DEVICE" "$version" "$xcode" | tee "$out/device.txt"
echo "::endgroup::"

echo "::group::The test's build"
build=0
wait "$builder" || build=$?
builder=""
tail -5 "$out/logs/test-build.log"
[ "$build" -eq 0 ] || { echo "::error::$TEST didn't build"; cat "$out/logs/test-build.log"; exit 1; }
echo "::endgroup::"

echo "::group::The screens ($orientation), through the driver"
status=0
proof="$work/proof"
start="$(date +%s)"
# (The launcher's simctl the same Xcode's.)
(cd "$ROOT" && "$BAZEL" test --test_output=streamed --test_env=ISOMER_SIMULATOR="$udid" ${DEVELOPER_DIR:+--test_env=DEVELOPER_DIR} \
    --test_env=ISOMER_PROOF="$proof" --test_env=VISOR_PROOF_SCREENS="$SCREENS" \
    --test_env=VISOR_PROOF_ORIENTATION="$orientation" \
    ${VISOR_PROOF_SETTLE_SECONDS:+--test_env=VISOR_PROOF_SETTLE_SECONDS} "$TEST") || status=1
echo "The screens took $(($(date +%s) - start)) s"
logs="$(cd "$ROOT" && "$BAZEL" info bazel-testlogs 2> /dev/null)/tests/feature_map_tests/feature_map_proof_ios"
cp -R "$logs/." "$out/logs/" 2> /dev/null || true
# Writable, as Bazel's outputs are not: the folder can be removed after.
chmod -R u+w "$out/logs" 2> /dev/null || true
xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
echo "::endgroup::"

# The driver's pictures (screens/ios/<device>/<screen>.png) as the proof's
# parts name them (tools/ci/proof_make.sh): ios-<screen>.png, on its side
# ios-<screen>-landscape.png, turned a quarter anticlockwise to stand as the
# screen is read (the app takes landscapeRight, as the probe's device
# turned to landscapeLeft did).
suffix=""
[ "$orientation" = portrait ] || suffix="-landscape"
for screen in $SCREENS; do
    picture="$(find "$proof/screens/ios" -name "$screen.png" 2> /dev/null | head -1)"
    if [ -z "$picture" ] || [ ! -s "$picture" ]; then
        echo "::error::no picture of $screen"
        status=1
        continue
    fi
    shot="$out/screens/ios-$screen$suffix.png"
    cp "$picture" "$shot"
    if [ "$orientation" = landscape ]; then
        python3 -I - "$shot" << 'PY'
import shutil, struct, subprocess, sys
with open(sys.argv[1], "rb") as f:
    width, height = struct.unpack(">II", f.read(24)[16:24])
if width < height:
    if shutil.which("sips"):
        subprocess.run(["sips", "-r", "270", sys.argv[1]], check=True, stdout=subprocess.DEVNULL)
    else:
        # Linux (an `ios` lease): Pillow's quarter turn anticlockwise, as
        # sips' 270 clockwise.
        from PIL import Image
        Image.open(sys.argv[1]).rotate(90, expand=True).save(sys.argv[1])
PY
    fi
done
count="$(find "$out/screens" -name 'ios-*.png' | wc -l | tr -d ' ')"
echo "$count iPhone screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
