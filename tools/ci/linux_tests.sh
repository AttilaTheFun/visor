#!/bin/bash
# The command-line server on Linux: built with SwiftPM, and the server
# tried — run, a throwaway session over its WebSocket, restarted,
# stopped (tools/probes/command_line_server.sh) — in a Linux container of
# Visor's agent image (Swift 6.4, node, aarch64): verify's linux job, a
# visor-jit runner of that image, right there, leasing nothing. Also the
# client's host services on their own: a file that uses Foundation without
# importing it fails here, as in Visor on Isomer (Package.swift's
# clientServices).
#
#   tools/ci/linux_tests.sh
#
#   VISOR_CI_IMAGE  unused here; the image CI's runner is
#
# The committed tree is unpacked apart from the checkout, so SwiftPM's
# .build stays out of Bazel's tree. Not on a Mac: Shireworks runs nothing in
# a container from one (no standard input, no mounts), so lease a container
# of the agent image and run it there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${VISOR_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.43.20}"

steps='set -e
mkdir -p /tmp/visor && tar -x -C /tmp/visor && cd /tmp/visor
swift --version
echo "::group::Build"
swift build --product visor-server
echo "::endgroup::"
echo "::group::Build the client services"
swift build --target VisorServices
echo "::endgroup::"
echo "::group::Try the server"
tools/probes/command_line_server.sh
echo "::endgroup::"'

# The committed tree, apart from the checkout. The file is in the job's own
# temporary folder, which the runner empties after the job.
if [ "$(uname -s)" != Linux ]; then
    echo "linux_tests: runs in a Linux container (CI's visor-jit, or a Shireworks container lease of the agent image): Shireworks has no way to run it in one from a Mac" >&2
    exit 2
fi
tree="${RUNNER_TEMP:-$(mktemp -d)}/visor-tree.tar"
git -C "$ROOT" archive --format=tar -o "$tree" HEAD
rm -rf /tmp/visor
exec sh -c "$steps" < "$tree"
