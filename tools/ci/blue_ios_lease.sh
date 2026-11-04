#!/bin/bash
# Blue Visor on the iPhone without a Mac of its own: the WasmKit app, the one
# compiled against Isomer's frameworks, the fixture probe
# (tests/isomer_ios_fixture) and the web site built in a Linux container
# leased from this Mac's OS Server (tools/ci/container_build.sh, with
# rules_applecross), then pictured on iOS leases as
# tools/isomer/snapshots/snapshots.py pictures them on a Mac:
#
#   ios, ios-landscape  the probe's testFixtureScreens and
#                       testFixtureScreensLandscape run on an iPhone 17 lease
#                       (`oss machine xctest`, as its runner's iPhone 17 on
#                       iOS 27.2), its pictures exported from the result
#                       bundles by xcresulttool on this Mac
#   web-mobile          the web site served where the lease reaches this Mac
#                       (its loopback, or this Mac's address on the network to
#                       OS Server's primary Mac VM, which runs the simulators:
#                       snapshots.py's lease_host) and opened in an iPhone 17
#                       Pro lease's Mobile Safari (`oss
#                       machine simctl openurl`, the lease's screenshots)
#
# then compared with tests/snapshots by snapshots.py, its run (report.html,
# manifests) in <run dir>. As tools/ci/ios_lease_proof.sh. The script fails
# as snapshots.py does (a changed or failed screen), or when a step fails.
#
#   tools/ci/blue_ios_lease.sh --image <agent image> --run <dir>
#
# Each lease is the script's alone: renewed while it runs, released however
# it ends (a kill nothing can trap leaves it its hour at most).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
export OSS

usage() { echo "usage: tools/ci/blue_ios_lease.sh --image <agent image> --run <dir>" >&2; exit 2; }
image=""
run_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="${2:?--image takes the agent image}"; shift 2 ;;
        --run) run_dir="${2:?--run takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$image" ] && [ -n "$run_dir" ] || usage
xcrun --find xcresulttool > /dev/null 2>&1 || { echo "$me: no xcresulttool on this Mac (Xcode's): the pictures can't be read from the result bundles" >&2; exit 1; }

work="$(mktemp -d)"
chmod 700 "$work"
built="$ROOT/.ci/blue-ios-build"
lease=""
renewer=""
child=""
finished=""
release() {
    if [ -n "$renewer" ]; then kill "$renewer" 2> /dev/null || true; wait "$renewer" 2> /dev/null || true; renewer=""; fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "$me: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    release
    rm -rf "$work"
    # The build's files too: the checkout is the runner's, kept between jobs.
    [ -z "${built:-}" ] || { chmod -R u+w "$built" 2> /dev/null || true; rm -rf "$built"; }
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Long commands run in the background and are waited for, so a signal (the
# runner cancelling the job) reaches the trap at once, not when they end.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}

# An iOS lease of the device named, renewed every ten minutes while the
# script lives (a cancel that kills it past its trap leaves no renewer: $$ is
# the script's, in the subshell too).
lease_ios() {
    echo "::group::An iOS lease ($1)"
    run "$OSS" machine lease ios --device="$1" --minutes=60 --wait --exports > "$work/lease"
    lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
    echo "Leased $lease"
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        while kill -0 "$$" 2> /dev/null; do
            sleep 600 &
            wait $!
            kill -0 "$$" 2> /dev/null || break
            "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
        done
    ) &
    renewer=$!
    echo "::endgroup::"
}

echo "::group::The apps, the fixture probe and the web site, built on Linux"
# --compilation_mode=opt, not -c opt: container_build tells options from
# targets by a leading dash.
(cd "$ROOT" && VISOR_CI_PACKAGE="$built" run bazel run //tools/ci:container_build -- "$image" \
    --compilation_mode=opt --ios_multi_cpus=sim_arm64 \
    //applications/visor_isomer_ios //applications/visor_isomer_compiled_ios \
    //tests/isomer_ios_fixture:fixture_shots //applications/visor_web:visor_web_site)
for file in "$built/visor_isomer_ios.ipa" "$built/visor_isomer_compiled_ios.ipa" "$built/fixture_shots.zip" "$built/visor_web_site"; do
    [ -e "$file" ] || { echo "$me: the build left no $(basename "$file")" >&2; exit 1; }
done
echo "::endgroup::"

# The fixture probe, in each orientation, on an iPhone 17 (its runner's).
lease_ios "iPhone 17"
"$OSS" machine simctl "$lease" ui booted appearance light
probe_status=0
mkdir -p "$work/results"
for orientation in portrait landscape; do
    case_name="testFixtureScreens"
    [ "$orientation" = portrait ] || case_name="testFixtureScreensLandscape"
    echo "::group::The fixture probe ($orientation)"
    # Its output kept too: snapshots.py's check of the search screen reads it.
    run "$OSS" machine xctest "$lease" --tests="$built/fixture_shots.zip" --host="$built/visor_isomer_ios.ipa" --ui \
        --only-testing="BlueFixtureShots/$case_name" \
        --junit="$work/results/$orientation.xml" --result="$work/results/$orientation.xcresult.zip" \
        > "$work/results/$orientation.log" 2>&1 || probe_status=1
    cat "$work/results/$orientation.log"
    echo "::endgroup::"
done
release

# The pictures: each attachment named fixture-<screen>, from its
# orientation's result bundle, where snapshots.py's ios targets take them.
pictures="$work/pictures"
for orientation in portrait landscape; do
    mkdir -p "$pictures/$orientation"
    cp "$work/results/$orientation.log" "$pictures/$orientation.log" 2> /dev/null || true
    result="$work/results/$orientation.xcresult.zip"
    [ -f "$result" ] || { echo "$me: the $orientation run left no result bundle" >&2; continue; }
    rm -rf "$work/unzipped" "$work/attachments"
    mkdir "$work/unzipped" "$work/attachments"
    ditto -x -k "$result" "$work/unzipped"
    bundle="$(find "$work/unzipped" -maxdepth 2 -name '*.xcresult' -type d | head -1)"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$work/attachments" > /dev/null
    python3 - "$work/attachments" "$pictures/$orientation" << 'PY'
import json, os, re, shutil, sys
source, out = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test.get("attachments", []):
        # The name the probe gave it, which xcresulttool suffixes with an
        # index and an identifier.
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", attachment.get("suggestedHumanReadableName", ""))
        if name.startswith("fixture-") and name.endswith(".png"):
            shutil.copy(os.path.join(source, attachment["exportedFileName"]), os.path.join(out, name))
PY
done

# Mobile Safari, on an iPhone 17 Pro (web-mobile's pictures'), then every
# target compared by snapshots.py.
lease_ios "iPhone 17 Pro"
mkdir -p "$run_dir/logs"
cp "$work/results"/* "$run_dir/logs"/ 2> /dev/null || true
snapshots_status=0
run env VISOR_SNAPSHOT_RUN_DIR="$run_dir/snapshots" VISOR_SNAPSHOT_IOS_PICTURES="$pictures" \
    VISOR_SNAPSHOT_IOS_LEASE="$lease" VISOR_SNAPSHOT_WEB_SITE="$built/visor_web_site" \
    python3 "$ROOT/tools/isomer/snapshots/snapshots.py" run --targets ios,ios-landscape,web-mobile || snapshots_status=$?
release

finished=1
[ "$probe_status" -eq 0 ] || exit "$probe_status"
exit "$snapshots_status"
