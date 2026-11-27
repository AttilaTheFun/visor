#!/bin/bash
# Visor on Android's part of the proof (ci.yml's verify), on one
# of GitHub's own Ubuntu runners (x86_64, with KVM): blue Visor's APK, built
# on Linux by the proof's build job for x86_64 with Isomer's driver in it
# (--config=drive: never a release's), installed on an emulator made here
# from the runner's Android SDK as Isomer's hermetic one is
# (@isomer//tools/android/emulator: API 34's AOSP image, 1080 by 1920 at
# 420 dpi; SwiftShader draws it, the same pixels every run), its status bar
# held still (System UI's demo mode, sent twice as snapshots.py sends it).
# The fixture's screens (snapshots.py's SCREENS) are pictured through
# Isomer's driver (//tests/feature_map_tests:feature_map_proof_android, its
# proof/FeatureMapProof.swift): one launch walking FEATURE_MAP.md to each
# screen it reaches, and a launch for each screen whose fixture differs;
# each pictured by Isomer's Android launcher (adb's screencap) once the
# driver says it has settled and two pictures in a row are the same, then
# cut below the status bar, as snapshots.py cuts it: its icons redraw
# between runs even in demo mode. On its side, the emulator is turned
# before the first: its rotation held at a quarter turn, auto-rotate off,
# and held so while the test runs. The test is built here by Bazel while
# the emulator boots and the APK builds.
#
#   tools/ci/proof_android.sh <apps> <out> [portrait|landscape]
#
# <apps> holds the signed APK (visor_android_apk.apk). Out come
# <out>/screens/android-<screen>.png (on its side,
# android-<screen>-landscape.png), <out>/logs/ (the emulator's, the test's
# and the launchers' logs) and <out>/device.txt (the emulator, for the
# proof's summary).
#
#   PROOF_BAZEL          the Bazel to build and run the test (default: bazel)
#   PROOF_ANDROID_SERIAL a device adb already reaches (a Shireworks
#                        `android` lease, `adb connect`ed), used as it is
#                        in place of an emulator made here: by hand, on
#                        any machine with adb (ADB, else the PATH's);
#                        its status bar is held as here
#
# Fails when the emulator doesn't boot, the test fails (a screen that never
# showed) or a screen has no picture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_android.sh <apps> <out> [portrait|landscape]" >&2; exit 2; }
[ $# -eq 2 ] || [ $# -eq 3 ] || usage
orientation="${3:-portrait}"
case "$orientation" in portrait | landscape) ;; *) usage ;; esac
suffix=""
[ "$orientation" = portrait ] || suffix="-landscape"
mkdir -p "$1" "$2"
apps="$(cd "$1" && pwd)"
out="$(cd "$2" && pwd)"
SCREENS="$(python3 -I -c 'import ast, sys
for line in open(sys.argv[1]):
    if line.startswith("SCREENS = "): print(" ".join(ast.literal_eval(line.split("=", 1)[1].strip())))' "$ROOT/tools/isomer/snapshots/snapshots.py")"
PACKAGE="com.loganshire.visor"
BAZEL="${PROOF_BAZEL:-bazel}"
# Its Swift packages' git fetches with the job's token (GH_TOKEN): GitHub
# limits anonymous git by address, which its runners share.
"$ROOT/tools/ci/git_auth.sh"
TEST=//tests/feature_map_tests:feature_map_proof_android
# 24dp at 2.625x, as snapshots.py's ANDROID_STATUS_BAR.
STATUS_BAR=80
IMAGE="system-images;android-34;default;x86_64"
[ -n "$SCREENS" ] || { echo "$me: no SCREENS in tools/isomer/snapshots/snapshots.py" >&2; exit 1; }
# Not there yet with PROOF_APPS_ARTIFACT: waited for once the emulator is up.
signed_apk() { ls "$apps"/*.apk 2> /dev/null | grep -v '_unsigned\.apk$' | head -1 || true; }
apk="$(signed_apk)"
[ -n "$apk" ] || [ -n "${PROOF_APPS_ARTIFACT:-}" ] || { echo "$me: no signed .apk in $apps" >&2; exit 1; }
serial="${PROOF_ANDROID_SERIAL:-}"
if [ -z "$serial" ]; then
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
    export ANDROID_AVD_HOME="$RUNNER_TEMP/avd"
fi
proof="$(mktemp -d)/proof"
emulator_pid=""
finished=""
builder=""
holder=""
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$builder" ] || kill "$builder" 2> /dev/null || true
    [ -z "$holder" ] || kill "$holder" 2> /dev/null || true
    if [ -n "$emulator_pid" ]; then
        "$sdk/platform-tools/adb" logcat -d > "$out/logs/logcat.txt" 2> /dev/null || true
        "$sdk/platform-tools/adb" emu kill > /dev/null 2>&1 || kill "$emulator_pid" 2> /dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$out/screens" "$out/logs" ${ANDROID_AVD_HOME:+"$ANDROID_AVD_HOME"}
# rules_swift's Linux toolchain wants clang as the C compiler, and Ubuntu's
# runner defaults to gcc (the first release run on main, 18 Nov 2026). Set
# for the test's run below too, so that Bazel keeps one configuration.
[ "$(uname -s)" != Linux ] || export CC=clang
# The test, built while the emulator boots (Bazel's own server; the run
# below waits for it). It links swift.org's Foundation, whose networking
# wants libcurl's and libxml2's development libraries, which Ubuntu's
# runner lacks.
(
    if [ "$(uname -s)" = Linux ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libcurl4-openssl-dev libxml2-dev \
            || { sudo apt-get update -qq && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
                libcurl4-openssl-dev libxml2-dev; }
    fi
    cd "$ROOT" && "$BAZEL" build "$TEST"
) > "$out/logs/test-build.log" 2>&1 &
builder=$!

if [ -n "$serial" ]; then
echo "::group::The device $serial"
adb="${ADB:-adb}"
export ANDROID_SERIAL="$serial"
"$adb" wait-for-device
else
echo "::group::An emulator (API 34, x86_64)"
# KVM for the runner's user: GitHub's Ubuntu runners have it, root's alone.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
sdkmanager="$(ls "$sdk"/cmdline-tools/*/bin/sdkmanager | sort -V | tail -1)"
avdmanager="${sdkmanager%/sdkmanager}/avdmanager"
# (`yes` ends on SIGPIPE when sdkmanager does, which pipefail would take
# for sdkmanager's failure.)
{ yes || true; } | "$sdkmanager" --install "$IMAGE" emulator platform-tools > "$out/logs/sdkmanager.txt" 2>&1 \
    || { tail -20 "$out/logs/sdkmanager.txt"; exit 1; }
echo no | "$avdmanager" create avd --force --name proof --package "$IMAGE" > /dev/null
# The AVD as Isomer's (run_emulator.sh's config.ini), on x86_64: these keys
# in place of any avdmanager wrote.
config="$ANDROID_AVD_HOME/proof.avd/config.ini"
for key in hw.ramSize hw.lcd.density hw.lcd.width hw.lcd.height hw.keyboard hw.mainKeys hw.gpu.enabled \
    disk.dataPartition.size PlayStore.enabled; do
    sed -i "/^$key *=/d" "$config"
done
cat >> "$config" << 'INI'
hw.ramSize=2048
hw.lcd.density=420
hw.lcd.width=1080
hw.lcd.height=1920
hw.keyboard=yes
hw.mainKeys=no
hw.gpu.enabled=yes
disk.dataPartition.size=2G
PlayStore.enabled=false
INI
adb="$sdk/platform-tools/adb"
"$sdk/emulator/emulator" -avd proof -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
    -camera-back none -camera-front none > "$out/logs/emulator.txt" 2>&1 &
emulator_pid=$!
"$adb" wait-for-device
booted=""
for _ in $(seq 1 120); do
    [ "$("$adb" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] && { booted=1; break; }
    kill -0 "$emulator_pid" 2> /dev/null || break
    sleep 5
done
[ -n "$booted" ] || { echo "$me: the emulator did not boot"; tail -30 "$out/logs/emulator.txt"; exit 1; }
serial="$("$adb" devices | awk '$2 == "device" { print $1; exit }')"
fi
"$adb" shell cmd uimode night no
# A fixed status bar: 9:41, Wi-Fi and a full battery; the cellular network
# hidden (the emulator draws a shown one differently from run to run); the
# whole sequence twice, a few seconds apart, as SystemUI may still be
# settling just after boot.
"$adb" shell settings put global sysui_demo_allowed 1
for attempt in 1 2; do
    [ "$attempt" = 1 ] || sleep 4
    for command in "exit" "enter" "clock -e hhmm 0941" "battery -e level 100 -e plugged false" \
        "network -e wifi show -e level 4 -e fully true" "network -e mobile hide" "network -e nosim hide" \
        "notifications -e visible false"; do
        # shellcheck disable=SC2086 # the command and its extras, a word each
        "$adb" shell am broadcast -a com.android.systemui.demo -e command $command > /dev/null
    done
done
# The APK, once the emulator is up: a job that starts with its run boots
# while the build job builds (PROOF_APPS_ARTIFACT, from PROOF_APPS_JOB).
if [ -z "$apk" ]; then
    "$ROOT/tools/ci/await_artifact.sh" "$PROOF_APPS_ARTIFACT" "$apps" "${PROOF_APPS_JOB:-build-android}"
    apk="$(signed_apk)"
fi
[ -n "$apk" ] || { echo "$me: no signed .apk in $apps" >&2; exit 1; }
"$adb" install -r "$apk" > /dev/null
printf 'Android %s (API %s, %s), %s\n' "$("$adb" shell getprop ro.build.version.release | tr -d '\r')" \
    "$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')" "$("$adb" shell getprop ro.product.cpu.abi | tr -d '\r')" \
    "$("$adb" shell wm size | tr -d '\r' | sed 's/^Physical size: //')" | tee "$out/device.txt"
echo "::endgroup::"

echo "::group::The test's build"
build=0
wait "$builder" || build=$?
builder=""
tail -5 "$out/logs/test-build.log"
[ "$build" -eq 0 ] || { echo "::error::$TEST didn't build"; cat "$out/logs/test-build.log"; exit 1; }
echo "::endgroup::"

echo "::group::The screens ($orientation), through the driver"
if [ "$orientation" = landscape ]; then
    # Window manager's own lock (the settings alone left API 34's display
    # upright, 12 Nov 2026), and held while the test runs: a launch's stop
    # puts the launcher, which stands upright, in front for a moment, and
    # on 12 Nov the display stayed upright after it for one screen in
    # eleven.
    "$adb" shell settings put system accelerometer_rotation 0
    "$adb" shell cmd window user-rotation lock 1
    (
        exec < /dev/null
        while sleep 1; do "$adb" shell cmd window user-rotation lock 1 > /dev/null 2>&1; done
    ) &
    holder=$!
    sleep 2
fi
status=0
start="$(date +%s)"
(cd "$ROOT" && "$BAZEL" test --test_output=streamed --test_env=ADB="$adb" --test_env=ANDROID_SERIAL="$serial" \
    --test_env=ISOMER_PROOF="$proof" --test_env=VISOR_PROOF_SCREENS="$SCREENS" \
    --test_env=VISOR_PROOF_ORIENTATION="$orientation" "$TEST") || status=1
echo "The screens took $(($(date +%s) - start)) s"
logs="$(cd "$ROOT" && "$BAZEL" info bazel-testlogs 2> /dev/null)/tests/feature_map_tests/feature_map_proof_android"
cp -R "$logs/." "$out/logs/" 2> /dev/null || true
# Writable, as Bazel's outputs are not: the folder can be removed after.
chmod -R u+w "$out/logs" 2> /dev/null || true
[ -z "$holder" ] || { kill "$holder" 2> /dev/null || true; holder=""; }
"$adb" shell am force-stop "$PACKAGE"
if [ -n "${PROOF_ANDROID_SERIAL:-}" ]; then
    # A device of one's own: upright again, its status bar left held.
    [ "$orientation" = portrait ] || "$adb" shell cmd window user-rotation lock 0 > /dev/null 2>&1 || true
else
    "$adb" shell am broadcast -a com.android.systemui.demo -e command exit > /dev/null || true
fi
echo "::endgroup::"

# The driver's pictures (screens/android/<device>/<screen>.png) as the
# proof's parts name them (tools/ci/proof_make.sh): android-<screen>.png,
# on its side android-<screen>-landscape.png, cut below the status bar.
suffix=""
[ "$orientation" = portrait ] || suffix="-landscape"
for screen in $SCREENS; do
    found="$(find "$proof/screens/android" -name "$screen.png" 2> /dev/null | head -1)"
    if [ -z "$found" ] || [ ! -s "$found" ]; then
        echo "::error::no picture of $screen"
        status=1
        continue
    fi
    picture="$out/screens/android-$screen$suffix.png"
    cp "$found" "$picture"
    python3 -I - "$ROOT/tools/isomer/snapshots" "$picture" "$STATUS_BAR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pngdiff
pngdiff.crop_top(sys.argv[2], int(sys.argv[3]))
PY
    if [ "$orientation" = landscape ] && ! python3 -I - "$picture" << 'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    width, height = struct.unpack(">II", f.read(24)[16:24])
sys.exit(0 if width > height else 1)
PY
    then
        echo "::error::$screen was pictured upright, not on its side"
        status=1
    fi
done
count="$(find "$out/screens" -name 'android-*.png' | wc -l | tr -d ' ')"
echo "$count Android screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
