#!/bin/bash
# Builds Visor's packages into dist/packages: the iPhone and iPad app (an
# .ipa signed for the team's devices) and the Mac's disk images (Visor and
# Visor Server, Developer ID, notarized: tools/release_mac.sh). CI's
# :build: runs it on the release Mac's runner; what is done with the
# packages then is the runner's.
#
#   tools/build_packages.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist/packages
rm -rf "$OUT"
mkdir -p "$OUT"
bazel build -c opt --ios_multi_cpus=arm64 //applications/visor_ios
cp "$(bazel cquery -c opt --ios_multi_cpus=arm64 --output=files //applications/visor_ios 2>/dev/null | grep '\.ipa$' | head -1)" "$OUT/Visor.ipa"
VERSION="$(plutil -extract CFBundleShortVersionString raw applications/visor_macos/Info.plist)"
tools/release_mac.sh "$VERSION"
cp "dist/Visor-$VERSION.dmg" "dist/Visor-Server-$VERSION.dmg" "$OUT/"
ls -l "$OUT"
