#!/bin/bash
# Visor's own Linux programs for the containers it makes (docs/co-tenancy.md,
# "Container images"): visor-server, which is also the agents' host when run
# as visor-agent-host (a link to it beside it), built for Linux on arm64 and
# linked fully static with Swift's Static Linux SDK (musl): they run in any
# image, whatever its C library. Visor.app carries the folder in
# Contents/Resources/Linux, and every container has it read-only at
# /opt/visor/bin.
#
#   tools/linux_programs.sh <folder>
#
# On Linux with Swift 6.4.0 (Visor's agent image, a CI container): the SDK
# is installed the first time, by its checksum (285 MB), and its link needs
# lld, libc++abi and libunwind spelled out. The folder gets the two
# programs, stripped, checked that they run, and nothing else.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?the folder for the programs}"
SDK_VERSION="6.4.0"
SDK="swift-${SDK_VERSION}-RELEASE_static-linux-0.1.0"
SDK_URL="https://download.swift.org/swift-${SDK_VERSION}-release/static-sdk/swift-${SDK_VERSION}-RELEASE/${SDK}.artifactbundle.tar.gz"
SDK_SHA256="47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e"
me="$(basename "$0")"

[ "$(uname -s)" = Linux ] || { echo "$me: builds on Linux (a container of Visor's agent image)" >&2; exit 1; }
swift --version 2>&1 | grep -q "Swift version ${SDK_VERSION%.0}" \
    || { echo "$me: needs Swift ${SDK_VERSION}, which the SDK is for: $(swift --version 2>&1 | head -1)" >&2; exit 1; }
swift sdk list 2>/dev/null | grep -qx "$SDK" || swift sdk install "$SDK_URL" --checksum "$SDK_SHA256"

cd "$ROOT"
swift build -c release --swift-sdk aarch64-swift-linux-musl \
    -Xswiftc -use-ld=lld -Xlinker -lc++abi -Xlinker -lunwind \
    --scratch-path "${VISOR_LINUX_PROGRAMS_SCRATCH:-$ROOT/.build/linux-programs}" --product visor-server
built="$(swift build -c release --swift-sdk aarch64-swift-linux-musl \
    --scratch-path "${VISOR_LINUX_PROGRAMS_SCRATCH:-$ROOT/.build/linux-programs}" --show-bin-path)/visor-server"

mkdir -p "$OUT"
rm -f "$OUT/visor-server" "$OUT/visor-agent-host"
cp "$built" "$OUT/visor-server"
if command -v llvm-strip > /dev/null; then llvm-strip "$OUT/visor-server"; else strip "$OUT/visor-server"; fi
chmod 755 "$OUT/visor-server"
ln -s visor-server "$OUT/visor-agent-host"

# Static, and both of its names answer.
! ldd "$OUT/visor-server" > /dev/null 2>&1 || { echo "$me: $OUT/visor-server is linked dynamically" >&2; exit 1; }
"$OUT/visor-agent-host" --version > /dev/null || { echo "$me: visor-agent-host does not run" >&2; exit 1; }
answer="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' | "$OUT/visor-agent-host" mcp)"
case "$answer" in *'"result":{}'*) ;; *) echo "$me: visor-agent-host mcp answered: $answer" >&2; exit 1 ;; esac
ls -l "$OUT"
