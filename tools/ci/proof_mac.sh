#!/bin/bash
# The Mac's part of the proof (ci.yml's verify), on one of
# GitHub's own Macs (`xcode-27`, a desktop session whose shell may picture
# the screen): Visor.app (applications/visor_mac), built on Linux by the
# proof's build job and signed ad hoc there, opened on the screenshot
# fixture in the light look, once for each of the fixture's screens (each
# failing if the app is still busy once it should have settled), on a
# screen of 1920 by 1080 points (displayplacer; the runner's own is 1024 by
# 768, too narrow for the sidebar, the chat and the inspector together:
# Visor's split view looped until AppKit stopped it, visor#240). Each
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
SCREENS="sessions machines chat question goal inspector models search connect runner runner-accounts new-session commands settings settings-empty settings-split settings-later settings-docs settings-stack settings-stub"
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
identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
codesign --verify --verbose=1 "$app" 2>&1 | tail -2 || true
# The screen made 1920 by 1080, which its modes include; said either way.
brew install displayplacer > /dev/null 2>&1 || true
screen_id="$(displayplacer list 2> /dev/null | sed -n 's/^Persistent screen id: //p' | head -1 || true)"
if [ -z "$screen_id" ] || ! displayplacer "id:$screen_id res:1920x1080 scaling:off origin:(0,0) degree:0" > /dev/null 2>&1; then
    echo "::warning::The runner's screen stayed as it was (displayplacer)"
fi
screen_size="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); const f = $.NSScreen.mainScreen.frame; `${f.size.width} by ${f.size.height}`')"
printf 'macOS %s, a screen %s points\n' "$(sw_vers -productVersion)" "$screen_size" | tee "$out/device.txt"
# No "quit unexpectedly" dialog over the screens after a crash (a crash is
# the screen's failure, and its log says so), as OS Server's guests have.
defaults write com.apple.CrashReporter DialogType -string none

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
# The runner's scroll bars, as it has them, put back after a screen that
# asks for overlay ones (`<screen>-overlay`: the same screen with scroll
# bars only while scrolling, as a Mac with a trackpad has them).
scrollbars="$(defaults read -g AppleShowScrollBars 2> /dev/null || true)"
echo "The runner's scroll bars: ${scrollbars:-unset (Automatic)}"
for screen in $SCREENS; do
    echo "::group::$screen"
    case "$screen" in
        *-overlay) defaults write -g AppleShowScrollBars WhenScrolling; fixture="${screen%-overlay}" ;;
        *) fixture="$screen" ;;
    esac
    # Each launch a first one, whatever the one before did (a crash left
    # its windows to be restored: Settings over every screen after it).
    rm -rf "$HOME/Library/Saved Application State/$identifier.savedState"
    defaults delete "$identifier" > /dev/null 2>&1 || true
    # Opened as apps are, so it comes to the front with its window key, on
    # the fixture, with no windows restored from the run before, and a text
    # field's caret held lit rather than blinking (AppKit's blink periods,
    # in milliseconds): a picture caught it lit or not from run to run
    # (visor#244).
    open -n --stdout "$out/logs/$screen.log" --stderr "$out/logs/$screen.log" "$app" --args \
        -visor.fixture snapshot -visor.fixture.screen "$fixture" -visor.fixture.appearance light \
        -ApplePersistenceIgnoreState YES \
        -NSTextInsertionPointBlinkPeriodOn 100000000 -NSTextInsertionPointBlinkPeriodOff 0.001
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
    # Settled means still: an app whose main thread spins in layout or in
    # SwiftUI's updates (Logan's MacBook, 9 Nov 2026: a closed loop in the
    # chat column beside an inspector) fails its screen, pictured or not.
    cpu="$(ps -o %cpu= -p "$pid" 2> /dev/null | tr -d ' ' || true)"
    if [ -n "$cpu" ] && [ "${cpu%%.*}" -ge 50 ]; then
        echo "::error::$screen: the app is busy at ${cpu}% CPU after ${settle} s, not settled"
        status=1
    fi
    echo "$screen: ${cpu:-?}% CPU once settled"
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
    case "$screen" in
        *-overlay)
            if [ -n "$scrollbars" ]; then defaults write -g AppleShowScrollBars "$scrollbars"; else defaults delete -g AppleShowScrollBars 2> /dev/null || true; fi ;;
    esac
    echo "::endgroup::"
done
count="$(find "$out/screens" -name 'mac-*.png' | wc -l | tr -d ' ')"
echo "$count Mac screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
