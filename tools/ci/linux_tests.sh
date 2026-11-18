#!/bin/bash
# The command-line server on Linux: built with SwiftPM, and the server
# tried — run, a throwaway session over its WebSocket, restarted,
# stopped (tools/probes/command_line_server.sh) — on Linux: verify's linux
# job (GitHub's x86_64 Ubuntu, in Swift's image, Node 22 beside it), or a
# container of Visor's agent image. Also the client's host services on
# their own: a file that uses Foundation without importing it fails here,
# as in Visor on Isomer (Package.swift's clientServices).
#
#   tools/ci/linux_tests.sh
#
# The committed tree is unpacked apart from the checkout, so SwiftPM's
# .build stays out of Bazel's tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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
    echo "linux_tests: runs on Linux (CI's linux job, or a container of Visor's agent image)" >&2
    exit 2
fi
tree="${RUNNER_TEMP:-$(mktemp -d)}/visor-tree.tar"
git -C "$ROOT" archive --format=tar -o "$tree" HEAD
rm -rf /tmp/visor
exec sh -c "$steps" < "$tree"
