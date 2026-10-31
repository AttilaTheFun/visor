#!/bin/bash
# The command-line server on Linux: built, its tests run, and the server
# itself tried — run, a throwaway session over its WebSocket, restarted,
# stopped (tools/probes/command_line_server.sh) — in a container leased
# from OS Server, of Visor's agent image (Swift 6.4, node, aarch64). Also
# the client's host services on their own: a file that uses Foundation
# without importing it fails here, as in Visor on Isomer (Package.swift's
# clientServices).
#
#   tools/ci/linux_tests.sh
#
#   VISOR_CI_IMAGE  the image (default: the released agent image, below)
#
# The committed tree goes in on the command's standard input (git archive)
# and everything runs where it lands, through `oss machine run container
# --inside`, which holds a five-minute lease renewed while it runs and
# releases it however it ends: SIGTERM (the runner's cancel) releases it at
# once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${VISOR_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.43.20}"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"

steps='set -e
mkdir -p /tmp/visor && tar -x -C /tmp/visor && cd /tmp/visor
swift --version
echo "::group::Build"
swift build --product visor-server
echo "::endgroup::"
echo "::group::Build the client services"
swift build --target VisorServices
echo "::endgroup::"
echo "::group::Test"
swift test
echo "::endgroup::"
echo "::group::Try the server"
tools/probes/command_line_server.sh
echo "::endgroup::"'

# The tree from a file, not a pipe: exec then makes oss this process, so the
# runner's cancel reaches it, and it releases the container. The file is in
# the job's own temporary folder, which the runner empties after the job.
tree="${RUNNER_TEMP:-$(mktemp -d)}/visor-tree.tar"
git -C "$ROOT" archive --format=tar -o "$tree" HEAD
exec "$OSS" machine run container --image="$IMAGE" --cpus=6 --memory=8 --inside --workdir=/ -- sh -c "$steps" < "$tree"
