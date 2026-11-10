#!/bin/bash
# Visor's tests that need a Mac, built on Linux (tools/ci/mac_tests_build.sh,
# CI's build-tests job), run on one of GitHub's own Macs (`xcode-27`, the
# test job), which a public repository has for free, leaving Shireworks'
# Mac slots to the agents (Logan, 5 Nov 2026): each bundle by Xcode's
# `xctest` (`xcrun xctest`, as for any macOS logic test), a bundle at a
# time, stopped after 15 minutes, with Xcode 27.2 (the SDK they are built
# with) where the image has it. The tests with nothing of Apple's in them
# run on Linux (tools/ci/linux_tests.sh).
#
#   tools/ci/mac_tests_run.sh <archive.tar.gz> [--logs <dir>]
#
# --logs gets each bundle's test.log, laid out as bazel-testlogs is. The
# script fails as the tests do, after every bundle.
set -euo pipefail
me="$(basename "$0")"
usage() { echo "usage: tools/ci/mac_tests_run.sh <archive.tar.gz> [--logs <dir>]" >&2; exit 2; }
[ $# -ge 1 ] || usage
archive="$1"
shift
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --logs) logs="${2:?--logs takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi
xcodebuild -version | head -1

work="$(mktemp -d)"
finished=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$work/tests"
tar -xzf "$archive" -C "$work/tests"
[ -s "$work/tests/tests.txt" ] || { echo "$me: no tests.txt in $archive" >&2; exit 1; }

# A bundle's run, stopped after 15 minutes (macOS has no `timeout`).
xctest() {
    "$@" &
    local child=$! waited=0 status=0
    while kill -0 "$child" 2> /dev/null; do
        if [ "$waited" -ge 900 ]; then
            kill "$child" 2> /dev/null || true
            wait "$child" 2> /dev/null || true
            return 124
        fi
        sleep 5
        waited=$((waited + 5))
    done
    wait "$child" || status=$?
    return "$status"
}

status=0
while read -r name; do
    [ -n "$name" ] || continue
    out="$work/testlogs/$name"
    mkdir -p "$out" "$work/bundles/$name"
    ditto -x -k "$work/tests/$name.zip" "$work/bundles/$name"
    bundle="$(find "$work/bundles/$name" -maxdepth 1 -name '*.xctest' | head -1)"
    if [ -z "$bundle" ]; then
        echo "//$(dirname "$name"):$(basename "$name") FAILED: no .xctest in its zip"
        status=1
        continue
    fi
    echo "::group::$name"
    started=$SECONDS
    result=0
    xctest xcrun xctest "$bundle" > "$out/test.log" 2>&1 || result=$?
    [ "$result" -ne 124 ] || echo "stopped after 15 minutes" >> "$out/test.log"
    # Its failures alone (XCTest's `error: -[Class test]` lines, a Swift
    # Testing issue): the system logs errors of its own there too.
    grep -E 'error: -\[|failed \(|recorded an issue' "$out/test.log" | head -40 || true
    echo "::endgroup::"
    # XCTest's own count, the last of its "Executed N tests" lines (the
    # whole bundle's). A run that never started has none: without
    # `|| true`, set -e would end the script here, before its log is shown.
    executed="$(grep -E 'Executed [0-9]+ tests?' "$out/test.log" | tail -1 | sed 's/^[[:space:]]*//' || true)"
    if [ "$result" -eq 0 ]; then
        echo "//$(dirname "$name"):$(basename "$name") PASSED in $((SECONDS - started))s: ${executed:-no count}"
    else
        echo "//$(dirname "$name"):$(basename "$name") FAILED ($result) in $((SECONDS - started))s: ${executed:-no count}"
        tail -40 "$out/test.log"
        status=1
    fi
done < "$work/tests/tests.txt"
if [ -n "$logs" ]; then
    mkdir -p "$logs"
    cp -R "$work/testlogs/." "$logs/"
fi
[ "$status" -eq 0 ] || echo "::error::Test failed ($status)"
finished=1
exit "$status"
