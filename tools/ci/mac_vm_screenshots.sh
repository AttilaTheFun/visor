#!/bin/bash
# The site's pictures (site/), in a macOS VM leased from OS Server
# (xcode-27.0): the Mac client on the screenshot fixture, its window shown
# in the VM's own desktop session and captured (tools/mac_screenshots),
# and the phone app on its iOS simulator (the probe's testSiteShots), all in
# the dark look.
#
#   tools/ci/mac_vm_screenshots.sh <folder>
#
# The pictures come out to <folder>: mac-<screen>.png and site-<screen>.png.
# The VM (tools/ci/mac_vm.sh) is the script's alone, released however it
# ends. The script fails as the first step that fails, after both ran.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?the folder the pictures are copied out to}"
. "$ROOT/tools/ci/mac_vm.sh"
mac_vm_start visor-ci

mac_vm_steps << 'STEPS'
    mac)
        mkdir -p shots && cd visor && bazel build //tools/mac_screenshots || exit
        tool="$(bazel cquery --output=files //tools/mac_screenshots 2> /dev/null | head -1)"
        # In the desktop session of the VM's user (the tool shows a window):
        # an SSH session has no window server of its own.
        for screen in chat question models inspector new-session; do
            sudo launchctl asuser "$(id -u)" "$PWD/$tool" "$screen" "$HOME/ci/shots/mac-$screen.png" dark || exit
        done
        ;;
    iphone)
        mkdir -p shots
        # The simulator the probe runs on, made ahead, with the status bar
        # pictures usually show.
        runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-0' | head -1)"
        sim="$(xcrun simctl create "BAZEL_TEST_iPhone 17_27.0" "iPhone 17" "$runtime")" || exit
        xcrun simctl boot "$sim" && xcrun simctl bootstatus "$sim" > /dev/null || exit
        xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
            --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 || exit
        (cd visor && VISOR_UI_CASES=VisorProbe/testSiteShots tools/ios_ui_tests.sh) || exit
        cp /private/tmp/visor_probe/site-*.png shots/
        ;;
STEPS

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

status=0
for step in mac iphone; do
    case "$step" in
        mac) title="Pictures (Mac)" ;;
        iphone) title="Pictures (iOS simulator)" ;;
    esac
    echo "::group::$title"
    step_status=0
    run in_vm "$step" || step_status=$?
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::$title failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
mac_vm_fetch shots "$OUT" || echo "mac_vm_screenshots.sh: no pictures to copy out" >&2
mac_vm_release
finished=1
exit "$status"
