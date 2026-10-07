#!/bin/bash
# Mints the development certificate and provisioning profile for
# a bundle id (the phone client's) on a Mac
# that has never signed it: builds a throwaway one-file app with automatic
# signing, so Xcode (signed into the Apple ID, Settings → Accounts) makes
# both. Plug the iPhone in first, so it is registered with the team.
# rules_apple then finds "iOS Team Provisioning Profile: <bundle id>".
#
#   tools/mint_profile/mint_profile.sh <bundle id> <team id> [device UDID] [entitlements] [ios|tvos]
# (the bundle id in applications/visor_ios/BUILD.bazel, the team in .bazelrc.user;
# `tvos` for the Apple TV's, applications/visor_tvos, the TV paired with Xcode).
# With an entitlements file (the app's own, e.g. applications/visor_ios/
# app.entitlements), the App ID gets those capabilities (push) and the
# profile carries them: what the wildcard profile cannot.
#
# A new device needs both profiles re-minted: the app's explicit one (this
# script with the app's bundle id and entitlements, the device plugged in),
# and the team's wildcard, which the widget uses. Once the app's own App ID
# exists, minting the app's bundle id again keeps using the explicit
# profile, so the wildcard is re-minted through a bundle id with no
# capabilities of its own (any throwaway id, no entitlements file). The
# device must be awake, unlocked and in Developer Mode.
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
PLATFORM="${5:-ios}"
. "$(dirname "$0")/lib.sh"
mint_auth
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mint_project "$WORK" "$TEAM" "$BUNDLE" "$PLATFORM" "$ENTITLEMENTS"
DESTINATION="generic/platform=iOS"
[ "$PLATFORM" = tvos ] && DESTINATION="generic/platform=tvOS"
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
