#!/bin/bash
# Whether a signed Mac app is what macOS will open, and opens: its
# signature whole (`codesign --verify --deep --strict`), Developer ID with
# the hardened runtime, accepted by Gatekeeper (`spctl`) and its
# notarization stapled (`stapler validate`); then opened as a user opens
# it (`open`), and still running a few seconds later. CI runs it on
# Visor Disk Utility's signed .zip on an `xcode-27` Mac (ci.yml's
# alpha-launch and release-launch, beside Visor.app's launch_check), before
# its release asset is proposed or attached. It's then quit.
#
#   tools/ci/mac_app_opens.sh [--ad-hoc] [--hold <seconds>] <app .zip or .app>
#
# --hold: how long it must stay up once running (10 seconds). --ad-hoc: a
# local build's ad hoc signature (a leased VM's bazel build), with no
# Developer ID, Gatekeeper or notarization to check: never in CI.
#
# Opening Visor Disk Utility only reads the disks (`diskutil apfs list` and
# `info`) and writes volumes.json for Visor in the user's Application
# Support; it changes no volume without an administrator's password. Run
# it on a CI Mac or a leased VM. macOS alone.
set -euo pipefail
fail() { echo "mac_app_opens: $*" >&2; exit 1; }
usage="usage: tools/ci/mac_app_opens.sh [--ad-hoc] [--hold <seconds>] <app .zip or .app>"

ad_hoc="" hold=10 package=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ad-hoc) ad_hoc=1; shift ;;
        --hold) hold="${2:?--hold takes seconds}"; shift 2 ;;
        -*) fail "unknown option $1; $usage" ;;
        *) [ -z "$package" ] || fail "one app at a time; $usage"; package="$1"; shift ;;
    esac
done
[ -n "$package" ] || fail "$usage"
[[ "$hold" =~ ^[1-9][0-9]*$ ]] || fail "--hold takes a whole number of seconds"
[ "$(uname -s)" = Darwin ] || fail "it opens a Mac app: macOS alone"

work="$(mktemp -d)"
pid=""
cleanup() {
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

case "$package" in
    *.zip)
        [ -f "$package" ] || fail "no such file: $package"
        ditto -x -k "$package" "$work" || fail "$(basename "$package") doesn't unzip"
        apps=("$work"/*.app)
        ;;
    *.app) apps=("$package") ;;
    *) fail "$(basename "$package") is neither a Mac app's .zip nor an .app" ;;
esac
[ ${#apps[@]} -eq 1 ] && [ -d "${apps[0]}" ] || fail "$(basename "$package") holds ${#apps[@]} apps at its top, not one"
app="$(cd "${apps[0]}" && pwd -P)"
name="$(basename "$app")"

codesign --verify --deep --strict --verbose=2 "$app" || fail "$name's signature doesn't verify"
details="$(codesign --display --verbose=4 "$app" 2>&1)"
if [ -z "$ad_hoc" ]; then
    grep -q '^Authority=Developer ID Application: ' <<< "$details" || fail "$name isn't signed with Developer ID"
    grep -q '^CodeDirectory .*flags=.*runtime' <<< "$details" || fail "$name isn't signed with the hardened runtime"
    spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper refuses $name"
    xcrun stapler validate "$app" || fail "$name has no notarization ticket stapled"
fi
echo "mac_app_opens: $name: signed$([ -n "$ad_hoc" ] && echo " ad hoc" || echo ", Developer ID, notarized, accepted by Gatekeeper")"

# Opened by Launch Services, as a double click would, in the background;
# found by its executable's path, in this folder alone.
open -n -g "$app" || fail "$name doesn't open"
for _ in $(seq 1 30); do
    pid="$(pgrep -f -- "^$app/Contents/MacOS/" | head -1 || true)"
    [ -z "$pid" ] || break
    sleep 1
done
[ -n "$pid" ] || fail "$name wasn't running 30 seconds after it was opened"
sleep "$hold"
kill -0 "$pid" 2> /dev/null || { pid=""; fail "$name quit within $hold seconds of opening (see ~/Library/Logs/DiagnosticReports)"; }
echo "mac_app_opens: $name opened, and was still running $hold seconds later (pid $pid); quitting it"
