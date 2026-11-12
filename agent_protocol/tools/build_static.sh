#!/bin/bash
# agent-wrapper as one static file for each Linux architecture a container
# runs on, built with Swift's static Linux SDK (musl): it runs in any image,
# as multipass-client does (AttilaTheFun/multipass, tools/ci/build_client.sh).
#
# gRPC's transport brings NIOSSL, whose BoringSSL is C++. So the C++ is
# compiled against the SDK's libc++ (-stdlib=libc++), and the libstdc++ the
# toolchain names for C++ targets is the SDK's libc++ too: a libstdc++.a that
# links to it, first on the library path. Otherwise the host's GNU libstdc++
# is linked beside libc++, and every exception class is defined twice.
# Linked with lld, naming libc++abi and libunwind, and compiler-rt (the SDK
# has no libgcc); stripped as it links. The SDK goes into a folder of the
# run's (SWIFT_SDKS to reuse one), never ~/.swiftpm.
#
#   tools/build_static.sh <out>        (from agent_protocol/)
#
# Writes <out>/agent-wrapper-linux-arm64, -amd64 and SHA256SUMS.
set -euo pipefail
me="$(basename "$0")"
out="${1:?usage: $me <out>}"
cd "$(dirname "$0")/.."
swift_version="6.4.0"
sdk="swift-${swift_version}-RELEASE_static-linux-0.1.0"
sdk_url="https://download.swift.org/swift-${swift_version}-release/static-sdk/swift-${swift_version}-RELEASE/${sdk}.artifactbundle.tar.gz"
sdk_sha256="47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e"
said="$(swift --version 2>&1 | head -1)"
case "$said" in
    *"Swift version ${swift_version} "*|*"Swift version ${swift_version%.0} "*) ;;
    *) echo "$me: the static SDK is Swift ${swift_version}'s; this toolchain is: $said" >&2; exit 1 ;;
esac
work="${RUNNER_TEMP:-$(mktemp -d)}"
sdks="${SWIFT_SDKS:-$work/swift-sdks}"
mkdir -p "$sdks" "$out"
if ! swift sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -qx "$sdk"; then
    swift sdk install --swift-sdks-path "$sdks" "$sdk_url" --checksum "$sdk_sha256"
fi
for pair in aarch64:arm64 x86_64:amd64; do
    triple="${pair%%:*}"
    name="agent-wrapper-linux-${pair##*:}"
    libcxx="$(find "$sdks" -path "*musl*/$triple/usr/lib/libc++.a" | head -1)"
    [ -n "$libcxx" ] || { echo "$me: no libc++.a for $triple in the SDK" >&2; exit 1; }
    shim="$work/agent-wrapper-libstdcxx-$triple"
    mkdir -p "$shim"
    ln -sf "$libcxx" "$shim/libstdc++.a"
    scratch="$work/agent-wrapper-static-$triple"
    swift build -c release --product agent-wrapper --swift-sdks-path "$sdks" --swift-sdk "$triple-swift-linux-musl" \
        --scratch-path "$scratch" -Xcxx -stdlib=libc++ -Xlinker -L"$shim" \
        -Xswiftc -use-ld=lld -Xlinker -lc++abi -Xlinker -lunwind -Xlinker --strip-all \
        -Xswiftc -Xclang-linker -Xswiftc --rtlib=compiler-rt -Xswiftc -Xclang-linker -Xswiftc --unwindlib=libunwind
    built="$(find "$scratch" -path "*Release-staticlinux-$triple*" -name agent-wrapper -type f | head -1)"
    [ -n "$built" ] || { echo "$me: no agent-wrapper built for $triple" >&2; exit 1; }
    # Static: nothing to load, no interpreter.
    if readelf -d "$built" | grep -q NEEDED || readelf -l "$built" | grep -q INTERP; then
        echo "$me: $name is not static" >&2
        exit 1
    fi
    cp "$built" "$out/$name"
    chmod 755 "$out/$name"
done
(cd "$out" && sha256sum agent-wrapper-linux-* > SHA256SUMS)
cat "$out/SHA256SUMS"
