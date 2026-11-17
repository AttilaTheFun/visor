#!/bin/bash
# Visor's own Linux programs (tools/linux_programs.sh: visor-server, also
# the agents' host as visor-agent-host, linked fully static for arm64 with
# Swift's Static Linux SDK), built in CI's own job (linux-programs: GitHub's
# arm64 Ubuntu runner, in a container of Visor's agent image, which has the
# Swift the SDK is for, and checks that both programs run), and written to
# <file> as a tar (the link kept a link), for the signing job, which seals
# them into the Mac's app (tools/ci/mac_app_linux_programs.sh) before it is
# signed. The committed tree is unpacked apart from the checkout, so
# SwiftPM's .build stays out of it.
#
#   tools/ci/linux_programs.sh <file.tar>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?the tar file for the programs}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ "$(uname -s)" = Linux ] || { echo "linux_programs: builds on Linux (CI's linux-programs job, or a container of Visor's agent image)" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The checkout may be another user's (a job's container): safe here.
git -c safe.directory="$ROOT" -C "$ROOT" archive --format=tar HEAD | tar -x -C "$work"
mkdir -p "$work/out"
(cd "$work" && tools/linux_programs.sh "$work/out")
tar -c -f "$OUT" -C "$work/out" visor-server visor-agent-host
