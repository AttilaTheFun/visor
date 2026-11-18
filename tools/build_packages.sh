#!/bin/bash
# Builds the Mac's packages into dist/packages: its disk images (Visor and
# Visor Server, Developer ID, notarized: tools/release_mac.sh). CI's
# build job runs it on the release Mac's runner; what is done with the
# packages then is the runner's ($PIPELINE_CI). The iPhone and iPad app is
# no longer here: CI's alpha and release jobs build it on an xcode-27 Mac
# and sign it on Linux (tools/ci/sign_builds.sh), as they do Visor.app.
#
#   tools/build_packages.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist/packages
rm -rf "$OUT"
mkdir -p "$OUT"
VERSION="$(plutil -extract CFBundleShortVersionString raw applications/visor_macos/Info.plist)"
tools/release_mac.sh "$VERSION"
cp "dist/Visor-$VERSION.dmg" "dist/Visor-Server-$VERSION.dmg" "$OUT/"
ls -l "$OUT"
