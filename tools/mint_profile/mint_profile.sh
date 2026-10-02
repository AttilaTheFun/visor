#!/bin/bash
# Mints the development certificate and provisioning profile for
# a bundle id (the phone client's) on a Mac
# that has never signed it: builds a throwaway one-file app with automatic
# signing, so Xcode (signed into the Apple ID, Settings → Accounts) makes
# both. Plug the iPhone in first, so it is registered with the team.
# rules_apple then finds "iOS Team Provisioning Profile: <bundle id>".
#
#   tools/mint_profile/mint_profile.sh <bundle id> <team id> [device UDID] [entitlements]
# (the bundle id in applications/visor_ios/BUILD.bazel, the team in .bazelrc.user).
# With an entitlements file (the app's own, e.g. applications/visor_ios/
# app.entitlements), the App ID gets those capabilities (push) and the
# profile carries them: what the wildcard profile cannot.
#
# Xcode's own sign-in (Settings → Accounts) is not needed when an App Store
# Connect API key is set: VISOR_ASC_KEY_PATH, VISOR_ASC_KEY_ID and
# VISOR_ASC_ISSUER_ID, in the environment or in ~/.appstoreconnect/visor.env
# (local to the Mac; never in a repository).
set -euo pipefail
BUNDLE="${1:?bundle id, as BUNDLE_ID in applications/visor_ios/BUILD.bazel}"
TEAM="${2:?Apple team id, as VISOR_TEAM_ID in .bazelrc.user}"
DEVICE="${3:-}"
ENTITLEMENTS="${4:-}"
. "$(dirname "$0")/lib.sh"
mint_auth
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mint_project "$WORK" "$TEAM" "$BUNDLE" ios "$ENTITLEMENTS"
DESTINATION="generic/platform=iOS"
[ -n "$DEVICE" ] && DESTINATION="id=$DEVICE"
cd "$WORK"
# Xcode makes the certificate and the profile on the way to building; a
# build that then fails for another reason has still made them, so what
# is on disk afterwards is what counts.
visor_xcodebuild "$WORK/xcodebuild.log" "error|Signing Identity|Provisioning Profile|BUILD" \
    -project Mint.xcodeproj -scheme Mint -destination "$DESTINATION" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    -allowProvisioningDeviceRegistration -derivedDataPath "$WORK/derived" build \
    || { cp "$WORK/xcodebuild.log" "${TMPDIR:-/tmp}/visor-mint-profile.log"; echo "(kept as ${TMPDIR:-/tmp}/visor-mint-profile.log)" >&2; }
echo "--- profiles on disk for $BUNDLE:"
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE<"; then echo "$f"; fi
done
