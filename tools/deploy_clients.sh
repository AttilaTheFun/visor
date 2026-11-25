#!/bin/bash
# Builds and installs the iPhone and iPad app on a device. There's no Mac
# client app to install any more: the separate one retired (Logan, 24 Nov
# 2026), and Visor.app is the Mac's.
#
#   tools/deploy_clients.sh <iPhone UDID>      (or set VISOR_IPHONE_UDID)
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="${1:-${VISOR_IPHONE_UDID:-}}"
[ -n "$UDID" ] || { echo "usage: tools/deploy_clients.sh <iPhone UDID> (or set VISOR_IPHONE_UDID)" >&2; exit 2; }
bazel build //applications/visor_ios --ios_multi_cpus=arm64 -c opt
IPA="$(bazel cquery --ios_multi_cpus=arm64 -c opt --output=files //applications/visor_ios 2>/dev/null | head -1)"
xcrun devicectl device install app --device "$UDID" "$IPA"
echo "iPhone client installed"
