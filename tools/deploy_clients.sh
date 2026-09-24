#!/bin/bash
# Builds and installs the Mac client (relaunching it) and, when a device
# UDID is given, the iPhone client. The web client is published from the
# universal_visor repo (tools/publish_web.sh there) after bumping its visor pin.
#
#   tools/deploy_clients.sh [iPhone UDID]      (or set VISOR_IPHONE_UDID)
set -euo pipefail
cd "$(dirname "$0")/.."
bazel build -c opt //applications/visor_macos
ZIP="$(bazel cquery -c opt --output=files //applications/visor_macos 2>/dev/null | head -1)"
rm -rf /tmp/vmac && mkdir -p /tmp/vmac && unzip -qo "$ZIP" -d /tmp/vmac
pkill -x visor_macos || true; sleep 1
rm -rf /Applications/Visor.app && cp -R /tmp/vmac/visor_macos.app /Applications/Visor.app
open -a /Applications/Visor.app
echo "Mac client installed and relaunched"
UDID="${1:-${VISOR_IPHONE_UDID:-}}"
if [ -n "$UDID" ]; then
  bazel build //applications/visor_ios --ios_multi_cpus=arm64 -c opt
  IPA="$(bazel cquery --ios_multi_cpus=arm64 -c opt --output=files //applications/visor_ios 2>/dev/null | head -1)"
  xcrun devicectl device install app --device "$UDID" "$IPA"
  echo "iPhone client installed"
fi
