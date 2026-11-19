#!/bin/bash
# Visor's own Linux programs for the containers it makes: visor-server, which is also the agents' host when run
# as visor-agent-host (a link to it beside it), and relay-client, agent-proxy's
# end inside a relayed container (docs/agent-proxy.md; the container runner
# mounts it at /run/agent-proxy/client), built for Linux on arm64 and
# linked fully static with Swift's Static Linux SDK (musl): they run in any
# image, whatever its C library. Visor.app carries the folder in
# Contents/Resources/Linux, and every container has it read-only at
# /opt/visor/bin.
#
#   tools/linux_programs.sh <folder>
#
# On Linux with Swift 6.4.0 (Visor's agent image, a CI container): the SDK
# is installed the first time, by its checksum (285 MB), and its link needs
# lld, libc++abi and libunwind spelled out. The folder gets the programs
# (visor-server, the visor-agent-host link, relay-client), stripped,
# checked that they run, and nothing else.
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
scratch="${VISOR_LINUX_PROGRAMS_SCRATCH:-$ROOT/.build/linux-programs}"
# gRPC's transport (agent_protocol, VisorDriver) brings NIOSSL, whose
# BoringSSL is C++: compiled against the SDK's libc++ (-stdlib=libc++, not the
# host's GNU headers), and linked with it alone. The libstdc++ the toolchain
# names for C++ targets is a link to the SDK's libc++, first on the library
# path, or the host's would be linked beside it (agent_protocol's
# tools/build_static.sh does the same).
# Where SwiftPM put the SDK: under the home it takes ($HOME, else the
# account's), in .swiftpm or the XDG config folder. A GitHub job's container
# sets HOME to /github/home while SwiftPM may use root's: the search found
# nothing there and, a missing folder failing `find` under pipefail, the job
# ended with no word of why (the 0.61.2 release run, 18 Nov 2026).
sdk_homes=("$HOME" "$(getent passwd "$(id -u)" 2> /dev/null | cut -d: -f6)")
sdk_folders=()
for home in "${sdk_homes[@]}"; do
    [ -n "$home" ] || continue
    for folder in "$home/.swiftpm/swift-sdks" "${XDG_CONFIG_HOME:-$home/.config}/swiftpm/swift-sdks"; do
        [ -d "$folder" ] && sdk_folders+=("$folder")
    done
done
libcxx=""
[ "${#sdk_folders[@]}" -eq 0 ] \
    || libcxx="$(find "${sdk_folders[@]}" -path "*${SDK}*" -path "*musl*/aarch64/usr/lib/libc++.a" 2> /dev/null | head -1 || true)"
[ -n "$libcxx" ] || { echo "$me: no libc++.a for aarch64 in the static SDK (looked in: ${sdk_folders[*]:-no SDK folder under ${sdk_homes[*]}})" >&2; exit 1; }
shim="$scratch-libstdcxx"
mkdir -p "$shim"
ln -sf "$libcxx" "$shim/libstdc++.a"
for product in visor-server relay-client; do
    swift build -c release --swift-sdk aarch64-swift-linux-musl \
        -Xcxx -stdlib=libc++ -Xlinker -L"$shim" \
        -Xswiftc -use-ld=lld -Xlinker -lc++abi -Xlinker -lunwind \
        --scratch-path "$scratch" --product "$product"
done
bin="$(swift build -c release --swift-sdk aarch64-swift-linux-musl \
    -Xcxx -stdlib=libc++ -Xlinker -L"$shim" \
    --scratch-path "$scratch" --show-bin-path)"

mkdir -p "$OUT"
rm -f "$OUT/visor-server" "$OUT/visor-agent-host" "$OUT/relay-client"
for product in visor-server relay-client; do
    cp "$bin/$product" "$OUT/$product"
    if command -v llvm-strip > /dev/null; then llvm-strip "$OUT/$product"; else strip "$OUT/$product"; fi
    chmod 755 "$OUT/$product"
    # Static.
    ! ldd "$OUT/$product" > /dev/null 2>&1 || { echo "$me: $OUT/$product is linked dynamically" >&2; exit 1; }
done
ln -s visor-server "$OUT/visor-agent-host"

# Each name answers.
"$OUT/visor-agent-host" --version > /dev/null || { echo "$me: visor-agent-host does not run" >&2; exit 1; }
# The MCP server answers nothing without a session's variables (visor#442):
# stand-ins, as a ping reaches no server.
answer="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' |
    VISOR_PORT=1 VISOR_SESSION=linux-programs VISOR_TOKEN=linux-programs "$OUT/visor-agent-host" mcp)"
case "$answer" in *'"result":{}'*) ;; *) echo "$me: visor-agent-host mcp answered: $answer" >&2; exit 1 ;; esac
# relay-client's usage, without the container it's for (no network set up).
"$OUT/relay-client" help | grep -q "^Usage: relay-client run" || { echo "$me: relay-client does not run" >&2; exit 1; }
ls -l "$OUT"
