#!/bin/bash
# Visor's client as another app takes it (Package.swift's VisorClient,
# VisorUI and VisorServices; Shireworks' Visor tab), resolved with SwiftPM
# in a Linux container (verify's client-package job, visor-jit), as every
# job but the GUI proofs runs.
#
#   tools/ci/client_package.sh [work folder]
#
# 1. Visor's own package, resolved: every dependency its targets name.
# 2. A stand-in host, a package of its own beside the checkout, that takes
#    VisorUI as Shireworks does, with swift-crypto pinned to 3.x as Apple's
#    containerization holds it there: resolved, its graph loaded, and the
#    swift-crypto it took checked to be 3.x. A package's every target must
#    resolve, so this fails if the client takes a product 3.x lacks.
#
# Not compiled: VisorUI and the client's native services build only against
# Apple's SDK (SwiftUI, AVFoundation), which SwiftPM here hasn't got.
# Shireworks' own build compiles VisorUI when it takes a new Visor.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"

echo "::group::Visor's own resolution"
swift package --package-path "$ROOT" --scratch-path "$WORK/own" resolve
echo "::endgroup::"

host="$WORK/host"
rm -rf "$host"
mkdir -p "$host/Sources/Host"
cat > "$host/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Host",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Host", targets: ["Host"])],
    dependencies: [
        .package(path: "$ROOT"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    ],
    targets: [.target(name: "Host", dependencies: [.product(name: "VisorUI", package: "visor")])]
)
MANIFEST
printf 'import VisorUI\n' > "$host/Sources/Host/Host.swift"

echo "::group::A host with swift-crypto 3"
swift package --package-path "$host" --scratch-path "$WORK/host" resolve
crypto="$(swift package --package-path "$host" --scratch-path "$WORK/host" show-dependencies --format json \
    | python3 -I -c '
import json, sys
def walk(node):
    yield node
    for child in node.get("dependencies", []):
        yield from walk(child)
print(sorted({n["version"] for n in walk(json.load(sys.stdin)) if n.get("identity") == "swift-crypto"}))')"
echo "swift-crypto: $crypto"
echo "::endgroup::"
case "$crypto" in "['3."*"']") ;; *) echo "::error::the host took swift-crypto $crypto, not 3.x alone"; exit 1 ;; esac
echo "client_package: the client resolves as another app takes it"
