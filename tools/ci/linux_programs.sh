#!/bin/bash
# Visor's own Linux programs (tools/linux_programs.sh: visor-server, also
# the agents' host as visor-agent-host, linked fully static), built in a
# container leased from OS Server, of Visor's agent image at a build with
# the Swift the Static Linux SDK is for, and written to <file> as a tar (the
# link kept a link). CI's linux-programs job runs it on a runner of the OS
# Server's Mac for the build job, which seals them into the Mac's app
# (tools/release_mac.sh): the release Mac has no OS Server of its own.
#
#   tools/ci/linux_programs.sh <file.tar>
#
#   VISOR_CI_IMAGE  the image (default: below)
#
# The committed tree goes in on the container's standard input (git
# archive), the build's words come out on standard error and the programs on
# standard output, through `oss machine run container --inside` (on the
# server's Mac), which holds a lease renewed while it runs and releases it
# however it ends: SIGTERM (the runner's cancel) releases it at once. No
# volume is kept, so the SDK (285 MB) is fetched each time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?the tar file for the programs}"
IMAGE="${VISOR_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.43.132}"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"

steps='set -e
mkdir -p /tmp/visor && tar -x -C /tmp/visor && cd /tmp/visor
tools/linux_programs.sh /tmp/linux-programs >&2
tar -c -C /tmp/linux-programs visor-server visor-agent-host'

# The tree from a file, not a pipe: exec then makes oss this process, so the
# runner's cancel reaches it, and it releases the container. The file is in
# the job's own temporary folder, which the runner empties after the job.
tree="${RUNNER_TEMP:-$(mktemp -d)}/visor-programs-tree.tar"
git -C "$ROOT" archive --format=tar -o "$tree" HEAD
exec "$OSS" machine run container --image="$IMAGE" --cpus=6 --memory=12 --inside --workdir=/ -- sh -c "$steps" < "$tree" > "$OUT"
