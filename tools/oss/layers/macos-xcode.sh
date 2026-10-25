#!/bin/bash
# The xcode-<version> layer on macOS: dev plus that Xcode and its iOS
# simulator. Its build copies the oss server Mac's Xcode (its version must
# match) to /Applications first (tools/oss/README.md).
set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
test -d /Applications/Xcode.app || { echo "no /Applications/Xcode.app (the build copies it in)" >&2; exit 1; }
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
version="$(xcodebuild -version | head -1)"
if [ -n "${OSS_XCODE_VERSION:-}" ] && ! echo "$version" | grep -q "Xcode ${OSS_XCODE_VERSION}"; then
  echo "this is $version, not Xcode $OSS_XCODE_VERSION" >&2; exit 1
fi
# The iOS simulator runtime, from Apple (no Apple Account needed).
xcodebuild -downloadPlatform iOS
xcrun simctl list runtimes | grep -i ios
echo "xcode: $version"
