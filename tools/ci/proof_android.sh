#!/bin/bash
# Visor on Android's part of the proof (ci.yml's verify), on one
# of GitHub's own Ubuntu runners (x86_64, with KVM): blue Visor's APK, built
# on Linux by the proof's build job for x86_64, installed on an emulator
# made here from the runner's Android SDK as Isomer's hermetic one is
# (@isomer//tools/android/emulator: API 34's AOSP image, 1080 by 1920 at
# 420 dpi; SwiftShader draws it, the same pixels every run), its status bar
# held still (System UI's demo mode, sent twice as snapshots.py sends it).
# Each of the fixture's screens (snapshots.py's SCREENS) is opened with the
# intent snapshots.py sends, pictured once it has settled, and cut below the
# status bar, as snapshots.py cuts it: its icons redraw between runs even in
# demo mode. On its side, the emulator is turned before the first: its
# rotation held at a quarter turn, auto-rotate off.
#
#   tools/ci/proof_android.sh <apps> <out> [portrait|landscape]
#
# <apps> holds the signed APK (visor_android_apk.apk). Out come
# <out>/screens/android-<screen>.png (on its side,
# android-<screen>-landscape.png), <out>/logs/ (the emulator's and the
# app's logs) and <out>/device.txt (the emulator, for the proof's summary).
#
#   VISOR_SNAPSHOT_SETTLE  seconds a screen is given (default 8)
#
# Fails when the emulator doesn't boot or a screen has no picture, after
# every screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_android.sh <apps> <out> [portrait|landscape]" >&2; exit 2; }
[ $# -eq 2 ] || [ $# -eq 3 ] || usage
orientation="${3:-portrait}"
case "$orientation" in portrait | landscape) ;; *) usage ;; esac
suffix=""
[ "$orientation" = portrait ] || suffix="-landscape"
apps="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
SCREENS="$(python3 -I -c 'import ast, sys
for line in open(sys.argv[1]):
    if line.startswith("SCREENS = "): print(" ".join(ast.literal_eval(line.split("=", 1)[1].strip())))' "$ROOT/tools/isomer/snapshots/snapshots.py")"
PACKAGE="com.loganshire.visor"
SETTLE="${VISOR_SNAPSHOT_SETTLE:-8}"
# 24dp at 2.625x, as snapshots.py's ANDROID_STATUS_BAR.
STATUS_BAR=80
IMAGE="system-images;android-34;default;x86_64"
[ -n "$SCREENS" ] || { echo "$me: no SCREENS in tools/isomer/snapshots/snapshots.py" >&2; exit 1; }
apk="$(ls "$apps"/*.apk 2> /dev/null | grep -v '_unsigned\.apk$' | head -1 || true)"
[ -n "$apk" ] || { echo "$me: no signed .apk in $apps" >&2; exit 1; }
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
export ANDROID_AVD_HOME="$RUNNER_TEMP/avd"
emulator_pid=""
finished=""
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    if [ -n "$emulator_pid" ]; then
        "$sdk/platform-tools/adb" logcat -d > "$out/logs/logcat.txt" 2> /dev/null || true
        "$sdk/platform-tools/adb" emu kill > /dev/null 2>&1 || kill "$emulator_pid" 2> /dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$out/screens" "$out/logs" "$ANDROID_AVD_HOME"

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
"$adb" install -r "$apk" > /dev/null
printf 'Android %s (API %s, %s), %s\n' "$("$adb" shell getprop ro.build.version.release | tr -d '\r')" \
    "$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')" "$("$adb" shell getprop ro.product.cpu.abi | tr -d '\r')" \
    "$("$adb" shell wm size | tr -d '\r' | sed 's/^Physical size: //')" | tee "$out/device.txt"
echo "::endgroup::"

echo "::group::The screens ($orientation)"
if [ "$orientation" = landscape ]; then
    "$adb" shell settings put system accelerometer_rotation 0
    "$adb" shell settings put system user_rotation 1
    sleep 2
fi
status=0
for screen in $SCREENS; do
    "$adb" shell am start -S -n "$PACKAGE/.MainActivity" --es fixture snapshot --es fixture.screen "$screen" > /dev/null
    sleep "$SETTLE"
    picture="$out/screens/android-$screen$suffix.png"
    "$adb" exec-out screencap -p > "$picture" || true
    if [ -s "$picture" ]; then
        python3 -I - "$ROOT/tools/isomer/snapshots" "$picture" "$STATUS_BAR" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pngdiff
pngdiff.crop_top(sys.argv[2], int(sys.argv[3]))
PY
        echo "$screen"
    else
        echo "::error::no picture of $screen"
        rm -f "$picture"
        status=1
    fi
done
"$adb" shell am force-stop "$PACKAGE"
"$adb" shell am broadcast -a com.android.systemui.demo -e command exit > /dev/null || true
echo "::endgroup::"
count="$(find "$out/screens" -name 'android-*.png' | wc -l | tr -d ' ')"
echo "$count Android screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
