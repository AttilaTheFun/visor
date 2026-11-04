#!/bin/bash
# Visor's tests that need a Mac (the server's Apple side, the client, its
# views and SSH, each an .xctest bundle: macos_unit_test), built on Linux in
# the job's own container (tools/ci/build_mac_tests.sh, below) and run on a
# slot of OS Server's primary Mac VM (`oss machine lease mac`: a macOS user
# of its own on a VM that stays up, ready in seconds), not in a VM leased
# and booted for the job: the macOS VMs are left to the agents that need
# one (Logan, 3 Nov 2026). The tests with nothing of Apple's in them run on
# Linux (tools/ci/linux_tests.sh).
#
#   tools/ci/mac_vm_tests.sh [--logs <dir>]
#
# --logs gets the tests' logs, laid out as bazel-testlogs is (each test's
# test.log and test.xml). The script fails as the tests do.
#
# Each bundle goes up and is run by `oss machine xctest` (xcodebuild
# test-without-building as the slot's user, outside any login session: none
# of these draws a window or keeps a token in a keychain), a bundle at a
# time, stopped after 15 minutes; its output and its JUnit come back.
# Several runs share the primary's loopback, so the tests that listen take
# ports the system chooses (ServerTestCase.freePort). The slot is the
# script's alone, released however it ends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
me="$(basename "$0")"

usage() { echo "usage: tools/ci/mac_vm_tests.sh [--logs <dir>]" >&2; exit 2; }
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --logs) logs="${2:?--logs takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done

work="$(mktemp -d)"
slot=""
child=""
finished=""
# The slot given back, the work deleted, however the script ends; an end
# before `finished` is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    [ -n "$slot" ] || slot="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$slot" ]; then
        "$OSS" machine release "$slot" || echo "$me: slot $slot was not released: oss machine release $slot" >&2
    fi
    rm -rf "$work"
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

# The build, in the job's own container (visor-jit: a Linux container with
# OS Server's read-only Bazel cache in its ~/.bazelrc and the cache's read
# token in its ~/.netrc, which opens OS Server's files too). Bazel fetches
# the SDK archive (container_build.sh's) and the ported tools from OS
# Server's files, by SHA-256, through the downloader config written here,
# its host the first of OSS_SERVERS (OSS_FILES_HOST names another).
sdk="$(sed -n 's/^SDK_SHA256="\(.*\)"$/\1/p' "$ROOT/tools/ci/container_build.sh")"
[ -n "$sdk" ] || { echo "$me: no SDK archive in tools/ci/container_build.sh" >&2; exit 1; }
host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="${OSS_SERVERS:-}"
    host="${host%%[ ,]*}"
    host="${host#*://}"
    host="${host%%[:/]*}"
fi
[ -n "$host" ] || { echo "$me: no host for OS Server's files (OSS_SERVERS): set OSS_FILES_HOST" >&2; exit 1; }
cat > "$work/downloader.cfg" << EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$sdk
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF
echo "::group::The tests, built on Linux"
echo "This container: $(nproc) CPUs, $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo 2> /dev/null) memory"
# And how much memory the build took (tools/ci/memory_watch.sh).
. "$ROOT/tools/ci/memory_watch.sh"
memory_watch_start
run bash -c 'cd "$0" && exec tools/ci/build_mac_tests.sh "$@"' "$ROOT" "$work/mac-tests.tar.gz" \
    --config=apple_on_linux --downloader_config="$work/downloader.cfg"
memory_watch_report "the Mac tests' build"
mkdir "$work/tests"
tar -xzf "$work/mac-tests.tar.gz" -C "$work/tests"
echo "::endgroup::"

echo "::group::A slot on the primary Mac"
started=$SECONDS
run "$OSS" machine lease mac --wait --minutes=30 --exports > "$work/lease"
slot="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Slot $slot, in $((SECONDS - started))s"
echo "::endgroup::"

echo "::group::The tests"
status=0
while read -r name; do
    out="$work/testlogs/$name"
    mkdir -p "$out"
    started=$SECONDS
    result=0
    run timeout 900 "$OSS" machine xctest "$slot" --tests="$work/tests/$name.zip" --junit="$out/test.xml" > "$out/test.log" 2>&1 \
        || result=$?
    [ "$result" -ne 124 ] || echo "stopped after 15 minutes" >> "$out/test.log"
    # XCTest's own count, the last of its "Executed N tests" lines (the
    # whole bundle's): a bundle that ran nothing says so (and `oss` fails it).
    executed="$(grep -E 'Executed [0-9]+ tests?' "$out/test.log" | tail -1 | sed 's/^[[:space:]]*//')"
    if [ "$result" -eq 0 ]; then
        echo "//$(dirname "$name"):$(basename "$name") PASSED in $((SECONDS - started))s: ${executed:-no count}"
    else
        echo "//$(dirname "$name"):$(basename "$name") FAILED ($result) in $((SECONDS - started))s: ${executed:-no count}"
        tail -40 "$out/test.log"
        status=1
    fi
done < "$work/tests/tests.txt"
echo "::endgroup::"
if [ -n "$logs" ]; then
    mkdir -p "$logs"
    cp -R "$work/testlogs/." "$logs/"
fi
[ "$status" -eq 0 ] || echo "::error::Test failed ($status)"
finished=1
exit "$status"
