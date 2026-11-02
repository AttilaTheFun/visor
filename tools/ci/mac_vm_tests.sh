#!/bin/bash
# Visor's tests that need a Mac (the server's Apple side, the client, its
# views and SSH, each an .xctest bundle: macos_unit_test), built on Linux in
# the job's own container (tools/ci/build_mac_tests.sh, below) and run in a
# macOS VM leased from OS Server (xcode_27_2), which gets the bundles alone:
# no tree, no Bazel. The tests with nothing of Apple's in them run on Linux
# (tools/ci/linux_tests.sh). As reviews' tools/ci/mac_vm_tests.sh, for
# bundles rather than swift_test's executables: OS Server's Mac test slot
# will take the same .zip.
#
#   tools/ci/mac_vm_tests.sh [--logs <dir>]
#
# --logs gets the tests' logs, laid out as bazel-testlogs is (each test's
# test.log). The script fails as the tests do.
#
# Each bundle is unzipped and run by the installed Xcode's
# `xcrun xctest <bundle>.xctest`, in an environment of its own (a scratch
# TMPDIR and TEST_TMPDIR, nothing of the job's), a bundle at a time,
# stopped after 15 minutes. The VM (tools/ci/mac_vm.sh) is the script's
# alone, released however it ends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"

usage() { echo "usage: tools/ci/mac_vm_tests.sh [--logs <dir>]" >&2; exit 2; }
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --logs) logs="${2:?--logs takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done

mac_vm_start visor-ci

mac_vm_steps << 'STEPS'
    test)
        cd tests || exit
        status=0
        while read -r name; do
            unpacked="$PWD/$name.bundle"
            out="$HOME/ci/testlogs/$name"
            temporary="$(mktemp -d)"
            mkdir -p "$out" "$unpacked"
            started=$SECONDS
            ditto -x -k "$name.zip" "$unpacked" || { echo "//$(dirname "$name"):$(basename "$name") FAILED: no bundle in $name.zip"; status=1; continue; }
            bundle="$(find "$unpacked" -maxdepth 2 -name '*.xctest' -type d | head -1)"
            (cd "$temporary" && exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" USER="$USER" \
                LANG=en_US.UTF-8 TMPDIR="$temporary/" TEST_TMPDIR="$temporary" \
                TEST_TARGET="//$(dirname "$name"):$(basename "$name")" \
                xcrun xctest "$bundle") > "$out/test.log" 2>&1 &
            test_process=$!
            (sleep 900 && kill -9 "$test_process" 2> /dev/null && echo "stopped after 15 minutes" >> "$out/test.log") &
            watchdog=$!
            result=0
            wait "$test_process" || result=$?
            kill "$watchdog" 2> /dev/null
            wait "$watchdog" 2> /dev/null
            # xctest's own count, the last of its "Executed N tests" lines
            # (the whole bundle's): a bundle that ran nothing says so.
            executed="$(grep -E 'Executed [0-9]+ tests?' "$out/test.log" | tail -1 | sed 's/^[[:space:]]*//')"
            if [ "$result" -eq 0 ]; then
                echo "//$(dirname "$name"):$(basename "$name") PASSED in $((SECONDS - started))s: ${executed:-no count}"
            else
                echo "//$(dirname "$name"):$(basename "$name") FAILED ($result) in $((SECONDS - started))s: ${executed:-no count}"
                tail -40 "$out/test.log"
                status=1
            fi
            rm -rf "$temporary"
        done < tests.txt
        exit "$status"
        ;;
    logs)
        tar -czf ~/ci/test-logs.tar.gz -C ~/ci/testlogs .
        ;;
STEPS

# The build, in the job's own container (visor-jit: a Linux container with
# OS Server's read-only Bazel cache in its ~/.bazelrc and the cache's read
# token in its ~/.netrc, which opens OS Server's files too): the tests built
# in the checkout, for the VM only to run. Bazel fetches the SDK archive
# (container_build.sh's) and the ported tools from OS Server's files, by
# SHA-256, through the downloader config written here, its host the first
# of OSS_SERVERS (OSS_FILES_HOST names another).
sdk="$(sed -n 's/^SDK_SHA256="\(.*\)"$/\1/p' "$ROOT/tools/ci/container_build.sh")"
[ -n "$sdk" ] || { echo "mac_vm_tests.sh: no SDK archive in tools/ci/container_build.sh" >&2; exit 1; }
host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="${OSS_SERVERS:-}"
    host="${host%%[ ,]*}"
    host="${host#*://}"
    host="${host%%[:/]*}"
fi
[ -n "$host" ] || { echo "mac_vm_tests.sh: no host for OS Server's files (OSS_SERVERS): set OSS_FILES_HOST" >&2; exit 1; }
cat > "$work/downloader.cfg" << EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$sdk
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF
echo "::group::The tests, built on Linux"
echo "This container: $(nproc) CPUs, $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo 2> /dev/null) memory"
run bash -c 'cd "$0" && exec tools/ci/build_mac_tests.sh "$@"' "$ROOT" "$work/mac-tests.tar.gz" \
    --config=apple_on_linux --downloader_config="$work/downloader.cfg"
echo "::endgroup::"

echo "::group::A macOS VM (xcode_27_2)"
mac_vm_lease
mac_vm_copy_tests "$work/mac-tests.tar.gz"
echo "::endgroup::"

echo "::group::The tests"
status=0
run in_vm test || status=$?
echo "::endgroup::"
if [ -n "$logs" ]; then
    mkdir -p "$logs"
    if run in_vm logs && mac_vm_fetch test-logs.tar.gz "$work/test-logs.tar.gz"; then
        tar -xzf "$work/test-logs.tar.gz" -C "$logs"
    else
        echo "mac_vm_tests.sh: no test logs" >&2
    fi
fi
[ "$status" -eq 0 ] || echo "::error::Test failed ($status)"
mac_vm_release
finished=1
exit "$status"
