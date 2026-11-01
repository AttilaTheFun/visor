#!/bin/bash
# CI's build of the apps in a Linux container (the Apple apps, the Linux
# client and blue Visor's Android APK, arm64), on a self-hosted runner's
# Mac: a container leased from that Mac's OS Server (`oss machine run
# container --inside`), made from this build's own agent image, so CI builds
# where a session's agent works. The Apple apps take Xcode 27.2's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository. Run with `bazel run //tools/ci:container_build`.
#
#   bazel run //tools/ci:container_build -- <image> [<bazel build args>…]
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   VISOR_CI_VOLUME  Bazel's tree, kept between builds (default: visor-ci;
#                    `:keep`, so OS Server keeps it when the lease ends, and
#                    a cancelled run's SIGTERM releases the lease at once).
#                    One build at a time uses it (ci.yml's concurrency).
#
# With no build arguments (CI's run) it builds every app (the iPhone's for
# the simulator, the Mac's, the Linux client, blue Visor's Android APK) and
# the Mac's test bundles (run on a Mac: the test job),
# then, for the Mac, the libraries, the staging server and the command-line
# server: every target compiles in the Swift 6 mode with warnings as errors
# (tools/swift), so building is a check of its own.
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:?run it with bazel run}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
shift
VOLUME="${VISOR_CI_VOLUME:-visor-ci}"
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"

# The command line inside OS Server, or on the path.
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
APP="$(cd "$(dirname "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OSS")")/../.." && pwd)"

# `--inside` came in OS Server 0.12.0. An older oss takes it for an option it
# doesn't know and runs the build on this Mac instead: refused here.
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
if ! python3 -c 'import sys; v = [int(x) for x in sys.argv[1].split(".")[:3]] + [0, 0]; sys.exit(0 if v[:3] >= [0, 12, 0] else 1)' "$version"; then
    echo "container_build: needs OS Server 0.12.0 or later on this Mac (oss machine run --inside); it has $version" >&2
    exit 1
fi

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi

# MODULE.bazel's placeholders, to this Mac's OS Server.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

# In the container: the apps, then (CI's run) the Mac's own targets, each
# build reading the cache (--cache writes the container's ~/.bazelrc).
steps='
root=$1 full=$2; shift 2
cd "$root"
flags="--keep_going --config=apple_on_linux --downloader_config=$root/.ci/downloader.cfg"
echo "::group::The apps"
bazel build $flags "$@"
apps=$?
echo "::endgroup::"
[ "$full" = 1 ] || exit $apps
echo "::group::The Mac: libraries, staging server, command-line server, Runner agent"
bazel build $flags --platforms=@apple_support//platforms:macos_arm64 \
    //libraries/... //tools/staging_server //applications/visor_server_mac:visor-server \
    //applications/visor_runner_agent:visor-runner-agent
mac=$?
echo "::endgroup::"
[ $apps -ne 0 ] && exit $apps
exit $mac
'

full=0
if [ $# -eq 0 ]; then
    full=1
    set -- --macos_cpus=arm64 \
        //applications/visor_ios \
        //applications/visor_macos \
        //applications/visor_menubar \
        //applications/visor_client_linux \
        //applications/visor_android:visor_android_apk \
        //tests/visor_server_tests \
        //tests/visor_client_tests \
        //tests/visor_ui_tests \
        //tests/visor_ssh_tests
fi

cd "$ROOT"
exec "$OSS" machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$full" "$@"
