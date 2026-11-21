#!/bin/bash
# Builds, signs (tools/sign_mac_app.sh) and installs the Mac client, Visor Client (relaunching it) and,
# when a device UDID is given, the iPhone client.
#
#   tools/deploy_clients.sh [iPhone UDID]      (or set VISOR_IPHONE_UDID)
set -euo pipefail
cd "$(dirname "$0")/.."
bazel build -c opt //applications/visor_macos
ZIP="$(bazel cquery -c opt --output=files //applications/visor_macos 2>/dev/null | head -1)"
rm -rf /tmp/vmac && mkdir -p /tmp/vmac && unzip -qo "$ZIP" -d /tmp/vmac
tools/sign_mac_app.sh "/tmp/vmac/Visor Client.app"
pkill -x "Visor Client" || true; sleep 1
rm -rf "/Applications/Visor Client.app" && cp -R "/tmp/vmac/Visor Client.app" "/Applications/Visor Client.app"
open -g -a "/Applications/Visor Client.app"
echo "Mac client installed and relaunched"
UDID="${1:-${VISOR_IPHONE_UDID:-}}"
if [ -n "$UDID" ]; then
  bazel build //applications/visor_ios --ios_multi_cpus=arm64 -c opt
  IPA="$(bazel cquery --ios_multi_cpus=arm64 -c opt --output=files //applications/visor_ios 2>/dev/null | head -1)"
  xcrun devicectl device install app --device "$UDID" "$IPA"
  echo "iPhone client installed"
fi
