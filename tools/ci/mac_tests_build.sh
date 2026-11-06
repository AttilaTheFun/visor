#!/bin/bash
# Visor's tests that need a Mac (the server's Apple side, the client, its
# views and SSH, each an .xctest bundle: macos_unit_test), built on Linux in
# the job's own container (CI's build-tests job, visor-jit: OS Server's
# read-only Bazel cache in its ~/.bazelrc and the cache's read token in its
# ~/.netrc, which opens OS Server's files too), for one of GitHub's own Macs
# to run (tools/ci/mac_tests_run.sh, the test job). Bazel fetches the SDK
# archive (container_build.sh's) and the ported tools from OS Server's
# files, by SHA-256, through the downloader config written here, its host
# the first of OSS_SERVERS (OSS_FILES_HOST names another).
#
#   tools/ci/mac_tests_build.sh <archive.tar.gz>
#
# The archive is tools/ci/build_mac_tests.sh's: each bundle's .zip at its
# package's path, and tests.txt naming them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
archive="${1:?usage: tools/ci/mac_tests_build.sh <archive.tar.gz>}"
case "$archive" in /*) ;; *) archive="$PWD/$archive" ;; esac
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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
cat > "$work/downloader.cfg" << CFG
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$sdk
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
CFG
echo "This container: $(nproc) CPUs, $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo 2> /dev/null) memory"
# And how much memory the build took (tools/ci/memory_watch.sh).
. "$ROOT/tools/ci/memory_watch.sh"
memory_watch_start
built=0
(cd "$ROOT" && tools/ci/build_mac_tests.sh "$archive" --config=apple_on_linux --downloader_config="$work/downloader.cfg") || built=$?
memory_watch_report "the Mac tests' build"
exit "$built"
