#!/bin/bash
# The Mac's part of the proof (ci.yml's verify), in the desktop session
# of a macOS VM that a Nimbus runner leases (tools/ci/mac_vm.sh --desktop): Visor.app (applications/visor_mac), built on a Nimbus runner
# by the proof's build job (build-apple) and signed ad hoc there, opened on the screenshot
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
#   VISOR_PROOF_SHOT       how a screen is pictured: screencapture (the
#                          default: the session's own, which needs Screen
#                          Recording) or framebuffer: the whole screen asked
#                          of whoever runs the Mac (<out>/.shots/<screen>.want
#                          answered with <screen>.png: tools/ci/mac_vm.sh
#                          --shots, Nimbus' picture of a VM's framebuffer,
#                          whose VMs may not picture their own screen yet),
#                          cut to the window here with sips
#   VISOR_PROOF_MAC_SCREENS  the screens, in place of all of them (a few,
#                          by hand in a VM)
#
# Fails when a screen's window never showed, after every screen.
set -euo pipefail
me="$(basename "$0")"
[ $# -eq 2 ] || { echo "usage: tools/ci/proof_mac.sh <apps> <out>" >&2; exit 2; }
apps="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
# A screen ending in a width (chat-320) is the same screen in a window that
# many points wide (the fixture's fixture.width): at 320, the content at its
# narrowest, the sidebar collapsed and the chat or the pane in what is left.
SCREENS="${VISOR_PROOF_MAC_SCREENS:-sessions machines chat question goal inspector models search connect new-session commands settings chat-320 inspector-320}"
SETTLE="${VISOR_SNAPSHOT_SETTLE:-8}"
SHOT="${VISOR_PROOF_SHOT:-screencapture}"
case "$SHOT" in screencapture | framebuffer) ;; *) echo "$me: VISOR_PROOF_SHOT is screencapture or framebuffer, not $SHOT" >&2; exit 2 ;; esac
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
screen_width="${screen_size%% by *}"
screen_width="${screen_width%%.*}"

# The window at <frame> (CoreGraphics' points: x,y,width,height) pictured
# into <file>: by the session itself, or cut from the whole screen's
# picture, which the Mac's runner gives (VISOR_PROOF_SHOT=framebuffer), at
# its scale (its pixels over the screen's points).
picture() {
    local frame="$1" file="$2" want="$out/.shots/$screen" x y w h pixels scale
    if [ "$SHOT" = screencapture ]; then
        screencapture -x -R"$frame" "$file"
        return
    fi
    mkdir -p "$out/.shots"
    rm -f "$want.png"
    touch "$want.want"
    for _ in $(seq 1 120); do
        [ -s "$want.png" ] && break
        sleep 0.5
    done
    [ -s "$want.png" ] || { echo "::error::$screen: no picture of the screen came (VISOR_PROOF_SHOT=framebuffer)"; return 1; }
    pixels="$(sips -g pixelWidth "$want.png" | awk '/pixelWidth/ { print $2 }')"
    scale=$((pixels / screen_width))
    [ "$scale" -ge 1 ] || scale=1
    IFS=, read -r x y w h <<< "$frame"
    sips -c $((h * scale)) $((w * scale)) --cropOffset $((y * scale)) $((x * scale)) "$want.png" --out "$file" > /dev/null
}
printf 'macOS %s, a screen %s points\n' "$(sw_vers -productVersion)" "$screen_size" | tee "$out/device.txt"
# No "quit unexpectedly" dialog over the screens after a crash (a crash is
# the screen's failure, and its log says so), as Shireworks' guests have.
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
    width=()
    case "$screen" in
        *-overlay) defaults write -g AppleShowScrollBars WhenScrolling; fixture="${screen%-overlay}" ;;
        *-[0-9][0-9][0-9]) fixture="${screen%-*}"; width=(-visor.fixture.width "${screen##*-}") ;;
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
    # (visor#244). Its driver off (ISO_DRIVER=none): the app is built with
    # Isomer's (--config=drive, as the iPhone's is in the same build), but
    # nothing here drives it. Left on, it dials a hub that isn't there once
    # a second, and before each dial it reads the whole window through
    # accessibility, every menu opened: 50% of the runner's CPU on the
    # settings screen, 33% on commands (0.63's release run).
    open -n --env ISO_DRIVER=none --stdout "$out/logs/$screen.log" --stderr "$out/logs/$screen.log" "$app" --args \
        -visor.fixture snapshot -visor.fixture.screen "$fixture" -visor.fixture.appearance light ${width[@]+"${width[@]}"} \
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
    # The driver said nothing: it was off, so the CPU above is the app's own.
    if grep -q '^\[iso\] driver' "$out/logs/$screen.log" 2> /dev/null; then
        echo "::error::$screen: Isomer's driver dialled out (ISO_DRIVER=none didn't reach the app)"
        status=1
    fi
    # In front again, should another window have come over it.
    open -a "$app"
    sleep 1
    frame="$(osascript -l JavaScript "$work/windows.js" "$pid" \
        | awk -F'\t' '$1 == 0 { a = $4 * $5; if (a > best) { best = a; f = int($2) "," int($3) "," int($4) "," int($5) } } END { print f }')"
    if [ -n "$frame" ]; then
        picture "$frame" "$out/screens/mac-$screen.png" || status=1
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
rm -rf "$out/.shots"
count="$(find "$out/screens" -name 'mac-*.png' | wc -l | tr -d ' ')"
echo "$count Mac screens"
[ "$count" -gt 0 ] || status=1
finished=1
exit "$status"
