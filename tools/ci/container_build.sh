#!/bin/bash
# CI's build of the apps in a Linux container (the Apple apps, the Linux
# client and blue Visor's Android APK, arm64), on a self-hosted runner's
# Mac: a container leased from that Mac's OS Server (`oss machine run
# container --inside`), made from this build's own agent image, so CI builds
# where a session's agent works. The Apple apps take Xcode 27.0's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository. Run with `bazel run //tools/ci:container_build`.
#
#   bazel run //tools/ci:container_build -- <image> [<bazel build args>…]
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   VISOR_CI_VOLUME  Bazel's tree (default: one of the run's own, given back
#                    with the lease: a run a newer push cancels is killed
#                    before it releases its lease, which holds its volume for
#                    up to an hour, so a volume shared between runs would
#                    refuse the next one. Kept between runs, `:keep`, once
#                    OS Server releases a cancelled run's lease at once.)
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:?run it with bazel run}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
shift
VOLUME="${VISOR_CI_VOLUME:-visor-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}}"
SDK_SHA256="251c252f7f41bcd3e08655e49e182686682d705945f4a2807049b9051c606ebb"

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

if [ $# -eq 0 ]; then
    set -- --macos_cpus=arm64 \
        //applications/visor_ios \
        //applications/visor_macos \
        //applications/visor_menubar \
        //applications/visor_client_linux \
        //applications/visor_android:visor_android_apk
fi

cd "$ROOT"
exec "$OSS" machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128" \
    --inside --cache="$host" -- \
    bazel build --keep_going --config=apple_on_linux --downloader_config="$ROOT/.ci/downloader.cfg" "$@"
