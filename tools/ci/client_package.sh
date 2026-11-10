#!/bin/bash
# Visor's client as another app takes it (Package.swift's VisorClient,
# VisorUI and VisorServices; Shireworks' Visor tab): built with SwiftPM on a
# Mac, as nothing else of Visor's builds it so.
#
#   tools/ci/client_package.sh [work folder]
#
# 1. VisorUI on Visor's own resolution (Package.resolved: swift-crypto 4.x),
#    for macOS.
# 2. A stand-in host, a package of its own beside the checkout, that shows
#    VisorView in a TabView as Shireworks does, with swift-crypto pinned to
#    3.x as Apple's containerization holds it there: for macOS with SwiftPM
#    and for iOS with xcodebuild. A package's every target must resolve, so
#    this also fails if the Runner takes a product 3.x lacks.
#
# Run on verify's xcode-27 runner (Xcode 27.2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"

echo "::group::VisorUI, Visor's own resolution (macOS)"
xcrun swift build --package-path "$ROOT" --scratch-path "$WORK/own" --product VisorUI
echo "::endgroup::"

host="$WORK/host"
rm -rf "$host"
mkdir -p "$host/Sources/Host"
cat > "$host/Package.swift" << EOF
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
EOF
cat > "$host/Sources/Host/Tabs.swift" << 'EOF'
import SwiftUI
import VisorUI

/// Visor as one of a host's tabs, its Settings the host's to hold.
public struct Tabs: View {
    @State private var settings = false
    public init() {}
    public var body: some View {
        TabView {
            Tab("Visor", systemImage: "eye") { VisorView(settingsPresented: $settings) }
        }
    }
}
EOF

echo "::group::A host with swift-crypto 3 (macOS)"
xcrun swift build --package-path "$host" --scratch-path "$WORK/host-mac"
grep -A4 '"swift-crypto"' "$host/Package.resolved" | grep '"version"'
echo "::endgroup::"

echo "::group::A host with swift-crypto 3 (iOS)"
(cd "$host" && xcodebuild -scheme Host -destination "generic/platform=iOS" -derivedDataPath "$WORK/host-ios" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build -quiet)
echo "::endgroup::"
echo "client_package: VisorUI builds as another app takes it"
