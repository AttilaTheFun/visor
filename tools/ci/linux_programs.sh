#!/bin/bash
# Visor's own Linux programs (tools/linux_programs.sh: visor-server, also
# the agents' host as visor-agent-host, linked fully static), built in a
# container leased from Shireworks, of Visor's agent image at a build with
# the Swift the Static Linux SDK is for, and written to <file> as a tar (the
# link kept a link). CI's linux-programs job runs it on a runner of
# Shireworks' Mac for the build job, which seals them into the Mac's app
# (tools/release_mac.sh).
#
#   tools/ci/linux_programs.sh <file.tar>
#
#   VISOR_CI_IMAGE  the image (default: below)
#
# Through Shireworks' API (tools/ci/shireworks.sh, copied from
# AttilaTheFun/shireworks, with the job's SHIREWORKS_GRANT or
# SHIREWORKS_SERVERS): the container leased, the committed tree (git
# archive) put in it, the build run there, its words on this job's output,
# the programs' tar fetched back, and the lease released however the
# script ends (the runner's cancel too). No volume is kept, so the SDK
# (285 MB) is fetched each time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?the tar file for the programs}"
IMAGE="${VISOR_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.43.132}"
SW="$ROOT/tools/ci/shireworks.sh"

work="$(mktemp -d)"
SHIREWORKS_ID=""
finish() {
    local status=$?
    [ -z "$SHIREWORKS_ID" ] || sh "$SW" release "$SHIREWORKS_ID" || echo "linux_programs: lease $SHIREWORKS_ID was not released" >&2
    rm -rf "$work"
    exit "$status"
}
trap finish EXIT
trap 'exit 143' TERM INT

git -C "$ROOT" archive --format=tar -o "$work/tree.tar" HEAD
sh "$SW" lease container --image="$IMAGE" --cpus=6 --memory=12 --minutes=90 --label="visor linux-programs" > "$work/lease"
. "$work/lease"
sh "$SW" put "$SHIREWORKS_ID" "$work/tree.tar" /tmp/visor-tree.tar > /dev/null
sh "$SW" run "$SHIREWORKS_ID" -- sh -c 'set -e
mkdir -p /tmp/visor && tar -x -C /tmp/visor -f /tmp/visor-tree.tar && cd /tmp/visor
tools/linux_programs.sh /tmp/linux-programs
tar -c -f /tmp/linux-programs.tar -C /tmp/linux-programs visor-server visor-agent-host'
sh "$SW" get "$SHIREWORKS_ID" /tmp/linux-programs.tar "$OUT"
