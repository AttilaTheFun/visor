#!/bin/bash
# The site's pictures (site/), in a macOS VM leased from OS Server
# (xcode_27_2): the Mac client on the screenshot fixture, its window shown
# in the VM's own desktop session (tools/mac_screenshots, held up) and
# pictured from outside — the VM's screen through its lease, cropped to the
# window as CoreGraphics' window list gives its frame (nothing in the VM may
# capture the screen) — and the phone app on its iOS simulator (the probe's
# testSiteShots), all in the dark look.
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
        cd visor && bazel build //tools/mac_screenshots || exit
        # In an app of its own, opened as apps are, so it comes to the front
        # with its window key (a program started from SSH stays behind).
        app=~/ci/MacScreenshots.app
        rm -rf "$app" && mkdir -p "$app/Contents/MacOS" || exit
        cp "$(bazel cquery --output=files //tools/mac_screenshots 2> /dev/null | head -1)" "$app/Contents/MacOS/mac_screenshots" || exit
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
        codesign --force --sign - "$app" || exit
        # The windows on the screen, from CGWindowList (no permission needed
        # for owners and frames): "owner layer x y width height", one a line.
        cat > ~/ci/windows.js << 'JS'
ObjC.import('CoreGraphics');
const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
const out = [];
for (let i = 0; i < list.count; i++) {
  const w = list.objectAtIndex(i), b = w.objectForKey('kCGWindowBounds');
  out.push([ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')), ObjC.unwrap(w.objectForKey('kCGWindowLayer'))]
    .concat(['X', 'Y', 'Width', 'Height'].map(k => ObjC.unwrap(b.objectForKey(k)))).join('\t'));
}
out.join('\n');
JS
        ;;
    mac-show)
        # In the desktop session of the VM's user (the tool shows a window;
        # an SSH session has no window server of its own), held up, then
        # the windows on the screen once it has settled.
        pkill -x mac_screenshots; sleep 1
        sudo launchctl asuser "$(id -u)" open -n ~/ci/MacScreenshots.app --args "$1" /dev/null dark hold || exit
        sleep 8
        sudo launchctl asuser "$(id -u)" osascript -l JavaScript ~/ci/windows.js
        ;;
    mac-hide)
        pkill -x mac_screenshots; true
        ;;
    iphone)
        mkdir -p shots
        # The simulator the probe runs on, made ahead, with the status bar
        # pictures usually show.
        runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' | head -1)"
        sim="$(xcrun simctl create "BAZEL_TEST_iPhone 17_27.2" "iPhone 17" "$runtime")" || exit
        xcrun simctl boot "$sim" && xcrun simctl bootstatus "$sim" > /dev/null || exit
        xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
            --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 || exit
        (cd visor && VISOR_UI_CASES=VisorProbe/testSiteShots tools/ios_ui_tests.sh) || exit
        cp /private/tmp/visor_probe/site-*.png shots/
        ;;
STEPS

echo "::group::A macOS VM (xcode_27_2)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

# A screen of the Mac client: shown in the VM, the VM's screen pictured, and
# the picture cropped to the tool's largest window (with any sheet over it)
# in pixels: the menu bar spans the screen, its width in points against the
# picture's in pixels is the screen's scale.
mac_screen() {
    local screen="$1" rows whole frame points pixels scale x y w h
    rows="$(in_vm mac-show "$screen")" || return 1
    whole="$work/screen-$screen.png"
    run "$OSS" machine screenshot "$lease" "$whole" > /dev/null || return 1
    frame="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "mac_screenshots" && $2 == 0 { a = $5 * $6; if (a > best) { best = a; f = int($3) " " int($4) " " int($5) " " int($6) } } END { print f }')"
    points="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "Window Server" { print int($5); exit }')"
    [ -n "$frame" ] && [ -n "$points" ] || { echo "no window of mac_screenshots on the screen" >&2; return 1; }
    pixels="$(sips -g pixelWidth "$whole" | awk '/pixelWidth/ { print $2 }')"
    scale=$(( pixels / points ))
    read -r x y w h <<< "$frame"
    python3 "$ROOT/tools/isomer/snapshots/pngdiff.py" crop "$whole" $(( x * scale )) $(( y * scale )) $(( w * scale )) $(( h * scale )) \
        "$work/shots/mac-$screen.png" || return 1
    in_vm mac-hide
}
mkdir -p "$work/shots"

status=0
for step in mac iphone; do
    case "$step" in
        mac) title="Pictures (Mac)" ;;
        iphone) title="Pictures (iOS simulator)" ;;
    esac
    echo "::group::$title"
    step_status=0
    run in_vm "$step" || step_status=$?
    if [ "$step" = mac ] && [ "$step_status" -eq 0 ]; then
        for screen in chat question models inspector new-session; do
            mac_screen "$screen" || { step_status=1; break; }
        done
    fi
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::$title failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
mac_vm_fetch shots "$OUT" || mkdir -p "$OUT"
cp "$work"/shots/mac-*.png "$OUT"/ 2> /dev/null || true
# A step that said it worked but left no picture failed all the same.
for name in mac-chat site-chat; do
    [ -f "$OUT/$name.png" ] || { echo "::error::no $name.png"; [ "$status" -ne 0 ] || status=1; }
done
mac_vm_release
finished=1
exit "$status"
