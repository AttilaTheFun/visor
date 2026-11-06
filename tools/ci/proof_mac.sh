#!/bin/bash
# The Mac's part of the proof (.github/workflows/proof.yml), on one of
# GitHub's own Macs (`xcode-27`, a desktop session whose shell may picture
# the screen): Visor.app (applications/visor_mac), built on Linux by the
# proof's build job and signed ad hoc there, opened on the screenshot
# fixture in the light look, once for each of the fixture's screens. Each
# is pictured once it has settled, cropped to the app's window as
# CoreGraphics' window list gives its frame (with any sheet over it): no
# menu bar, Dock or wallpaper.
#
#   tools/ci/proof_mac.sh <apps> <out>
#
# <apps> holds visor_mac.zip. Out come <out>/screens/mac-<screen>.png,
# <out>/logs/ (the app's output for each screen) and <out>/device.txt (the
# Mac, for the proof's summary).
#
#   VISOR_SNAPSHOT_SETTLE  seconds a screen is given (default 8; the
#                          search's matches in messages, twice that more)
#
# Fails when a screen's window never showed, after every screen.
set -euo pipefail
me="$(basename "$0")"
[ $# -eq 2 ] || { echo "usage: tools/ci/proof_mac.sh <apps> <out>" >&2; exit 2; }
apps="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
SCREENS="sessions machines chat question goal inspector models search connect new-session commands"
SETTLE="${VISOR_SNAPSHOT_SETTLE:-8}"
[ -f "$apps/visor_mac.zip" ] || { echo "$me: no visor_mac.zip in $apps" >&2; exit 1; }

work="$(mktemp -d)"
pid=""
finished=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

ditto -x -k "$apps/visor_mac.zip" "$work"
app="$(find "$work" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "$me: no app in visor_mac.zip" >&2; exit 1; }
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
codesign --verify --verbose=1 "$app" 2>&1 | tail -2 || true
printf 'macOS %s, %s\n' "$(sw_vers -productVersion)" \
    "$(system_profiler SPDisplaysDataType 2> /dev/null | sed -n 's/^ *Resolution: //p' | head -1)" | tee "$out/device.txt"

# The windows of a process on the screen, from CGWindowList (owners and
# frames need no permission): "layer x y width height", one a line.
cat > "$work/windows.js" << 'JS'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
  const out = [];
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i), b = w.objectForKey('kCGWindowBounds');
    if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')) !== pid) continue;
    out.push([ObjC.unwrap(w.objectForKey('kCGWindowLayer'))]
      .concat(['X', 'Y', 'Width', 'Height'].map(k => ObjC.unwrap(b.objectForKey(k)))).join('\t'));
  }
  return out.join('\n');
}
JS

status=0
mkdir -p "$out/screens" "$out/logs"
for screen in $SCREENS; do
    echo "::group::$screen"
    # Opened as apps are, so it comes to the front with its window key, on
    # the fixture, with no windows restored from the run before.
    open -n --stdout "$out/logs/$screen.log" --stderr "$out/logs/$screen.log" "$app" --args \
        -visor.fixture snapshot -visor.fixture.screen "$screen" -visor.fixture.appearance light \
        -ApplePersistenceIgnoreState YES
    pid=""
    for _ in $(seq 1 30); do
        pid="$(pgrep -n -f "$app/Contents/MacOS/$executable" || true)"
        [ -z "$pid" ] || break
        sleep 1
    done
    if [ -z "$pid" ]; then
        echo "::error::$screen: the app did not start"
        status=1
        echo "::endgroup::"
        continue
    fi
    settle="$SETTLE"
    [ "$screen" != search ] || settle=$((SETTLE * 3))
    sleep "$settle"
    # In front again, should another window have come over it.
    open -a "$app"
    sleep 1
    frame="$(osascript -l JavaScript "$work/windows.js" "$pid" \
        | awk -F'\t' '$1 == 0 { a = $4 * $5; if (a > best) { best = a; f = int($2) "," int($3) "," int($4) "," int($5) } } END { print f }')"
    if [ -n "$frame" ]; then
        screencapture -x -R"$frame" "$out/screens/mac-$screen.png"
        echo "$screen: the window at $frame"
    else
        echo "::error::$screen: no window of the app on the screen"
        status=1
    fi
    kill "$pid" 2> /dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$pid" 2> /dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2> /dev/null || true
    pid=""
    echo "::endgroup::"
done
count="$(find "$out/screens" -name 'mac-*.png' | wc -l | tr -d ' ')"
echo "$count Mac screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
