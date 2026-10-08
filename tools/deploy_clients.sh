#!/bin/bash
# Builds, signs (tools/sign_mac_app.sh) and installs the Mac client (relaunching it), and the
# iPhone client: published to an update server for the phone to install over
# the air (`--publish <notes.md>`: updater-server, AttilaTheFun/updater, with
# the build's release notes), or installed over USB or the LAN on a device by
# its UDID, for debugging. The web client is published from the visor_isomer
# repo (tools/publish_web.sh there) after bumping its visor pin.
#
#   tools/deploy_clients.sh --publish <notes.md>   (a build for use)
#   tools/deploy_clients.sh [iPhone UDID]          (debugging; or set VISOR_IPHONE_UDID)
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=""
if [ "${1:-}" = "--publish" ]; then
  NOTES="${2:?--publish takes the release notes file}"
  [ -f "$NOTES" ] || { echo "No notes at $NOTES" >&2; exit 1; }
  command -v updater-server >/dev/null || { echo "updater-server is not on the PATH" >&2; exit 1; }
  shift 2
fi
bazel build -c opt //applications/visor_macos
ZIP="$(bazel cquery -c opt --output=files //applications/visor_macos 2>/dev/null | head -1)"
rm -rf /tmp/vmac && mkdir -p /tmp/vmac && unzip -qo "$ZIP" -d /tmp/vmac
tools/sign_mac_app.sh /tmp/vmac/Visor.app
pkill -x Visor || true; pkill -x visor_macos || true; sleep 1
rm -rf /Applications/Visor.app && cp -R /tmp/vmac/Visor.app /Applications/Visor.app
open -g -a /Applications/Visor.app
echo "Mac client installed and relaunched"
UDID="${1:-${VISOR_IPHONE_UDID:-}}"
if [ -n "$NOTES" ] || [ -n "$UDID" ]; then
  bazel build //applications/visor_ios --ios_multi_cpus=arm64 -c opt
  IPA="$(bazel cquery --ios_multi_cpus=arm64 -c opt --output=files //applications/visor_ios 2>/dev/null | head -1)"
fi
if [ -n "$NOTES" ]; then
  updater-server publish "$IPA" --notes-file "$NOTES"
  echo "iPhone client published to the update server"
elif [ -n "$UDID" ]; then
  xcrun devicectl device install app --device "$UDID" "$IPA"
  echo "iPhone client installed"
fi
