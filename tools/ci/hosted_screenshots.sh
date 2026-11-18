#!/bin/bash
# The site's pictures (site/), on one of GitHub's own Macs (`xcode-27`, a
# desktop session whose shell may picture the screen, as proof_mac.sh's):
# the Mac client on the screenshot fixture (tools/mac_screenshots, in an app
# of its own opened as apps are, so it comes to the front with its window
# key, then pictured by its own `screencapture` of its window), and the
# phone app on an iPhone 17 simulator of iOS 27.2 (the probe's
# testSiteShots, tools/ios_ui_tests.sh), all in the dark look. In place of
# the macOS VM Shireworks leased for it (Logan, 15 Nov 2026: a public
# repository's CI on GitHub's runners alone). The proof doesn't stand in for
# it: its pictures are the light look, for Reviews to compare.
#
#   tools/ci/hosted_screenshots.sh <folder>
#
# The pictures come out to <folder>: mac-<screen>.png and site-<screen>.png.
# Fails as the first step that failed, after both ran.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
OUT="${1:?usage: tools/ci/hosted_screenshots.sh <folder>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[ "$(uname -s)" = Darwin ] || { echo "$me: runs on a Mac (CI's xcode-27)" >&2; exit 2; }
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi
work="$(mktemp -d)"
finished=""
sim=""
# macOS's bash (3.2): an end before the last line is a failure, whatever $? says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    pkill -x mac_screenshots 2> /dev/null || true
    if [ -n "$sim" ]; then
        xcrun simctl shutdown "$sim" 2> /dev/null || true
        xcrun simctl delete "$sim" 2> /dev/null || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
cd "$ROOT"

mac() {
    bazel build //tools/mac_screenshots || return
    local app="$work/MacScreenshots.app" screen
    mkdir -p "$app/Contents/MacOS"
    cp "$(bazel cquery --output=files //tools/mac_screenshots 2> /dev/null | head -1)" "$app/Contents/MacOS/mac_screenshots" || return
    chmod 755 "$app/Contents/MacOS/mac_screenshots"
    cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>mac_screenshots</string>
	<key>CFBundleIdentifier</key><string>com.LoganShire.Visor.macScreenshots</string>
	<key>CFBundleName</key><string>mac_screenshots</string>
	<key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" || return
    for screen in chat question models inspector new-session; do
        pkill -x mac_screenshots 2> /dev/null || true
        # -W: until the tool has pictured its window and quit.
        open -W -n "$app" --args "$screen" "$OUT/mac-$screen.png" dark || return
        [ -f "$OUT/mac-$screen.png" ] || { echo "$me: no picture of the Mac's $screen" >&2; return 1; }
    done
}

iphone() {
    local runtime
    runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' | head -1)"
    if [ -z "$runtime" ]; then
        echo "::warning::This image has no iOS 27.2 simulator: downloading it"
        xcodebuild -downloadPlatform iOS -buildVersion 27.2 > "$work/download-platform.log" 2>&1 \
            || tail -20 "$work/download-platform.log"
        for _ in $(seq 1 24); do
            runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' | head -1)"
            [ -z "$runtime" ] || break
            sleep 5
        done
    fi
    [ -n "$runtime" ] || { echo "$me: no iOS 27.2 simulator on this runner" >&2; return 1; }
    # The simulator the probe runs on (tools/ios_ui_tests.sh finds it by
    # this name), made ahead, with the status bar pictures usually show.
    sim="$(xcrun simctl create "BAZEL_TEST_iPhone 17_27.2" "iPhone 17" "$runtime")" || return
    xcrun simctl boot "$sim" && xcrun simctl bootstatus "$sim" > /dev/null || return
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 || return
    VISOR_UI_CASES=VisorProbe/testSiteShots tools/ios_ui_tests.sh || return
    cp /private/tmp/visor_probe/site-*.png "$OUT"/
}

status=0
for step in mac iphone; do
    echo "::group::Pictures ($step)"
    step_status=0
    "$step" || step_status=$?
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::Pictures ($step) failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
# A step that said it worked but left no picture failed all the same.
for name in mac-chat site-chat; do
    [ -f "$OUT/$name.png" ] || { echo "::error::no $name.png"; [ "$status" -ne 0 ] || status=1; }
done
finished=1
exit "$status"
