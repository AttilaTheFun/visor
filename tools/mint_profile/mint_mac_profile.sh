#!/bin/bash
# Mints the Mac client's Developer ID provisioning profile, with the
# capabilities its entitlements ask for (push): archives a throwaway one-file
# Mac app with automatic signing, then exports it for Developer ID, which is
# when Xcode makes the profile ("Mac Team Direct Provisioning Profile: <bundle
# id>"). tools/sign_mac_app.sh then embeds it and signs with what it grants.
# Signs in with the App Store Connect API key in ~/.appstoreconnect/visor.env
# when there is one (see mint_profile.sh), else Xcode's own account.
#
#   tools/mint_profile/mint_mac_profile.sh <bundle id> <team id> <entitlements>
# (applications/visor_macos/app.entitlements; the team in .bazelrc.user)
set -euo pipefail
BUNDLE="${1:?bundle id}"
TEAM="${2:?Apple team id, as VISOR_TEAM_ID in .bazelrc.user}"
ENTITLEMENTS="${3:?entitlements file}"
. "$(dirname "$0")/lib.sh"
mint_auth
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mint_project "$WORK" "$TEAM" "$BUNDLE" macos "$ENTITLEMENTS"
cd "$WORK"
visor_xcodebuild "$WORK/archive.log" "error|BUILD|ARCHIVE" \
    -project Mint.xcodeproj -scheme Mint -configuration Debug -archivePath "$WORK/Mint.xcarchive" -derivedDataPath "$WORK/derived" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive \
    || { cp "$WORK/archive.log" "${TMPDIR:-/tmp}/visor-mint-mac-archive.log"; echo "(kept as ${TMPDIR:-/tmp}/visor-mint-mac-archive.log)" >&2; exit 1; }
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>export</string>
</dict></plist>
PLIST
# The export is where Xcode makes the Developer ID profile. It can make it
# and still fail to export (its cloud signing wants an Admin key); what is
# on disk afterwards is what counts, and developer_id_profile.swift is the
# way when there is nothing.
visor_xcodebuild "$WORK/export.log" "error|EXPORT" \
    -exportArchive -archivePath "$WORK/Mint.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
    -exportPath "$WORK/out" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    || { cp "$WORK/export.log" "${TMPDIR:-/tmp}/visor-mint-mac-export.log"; echo "(kept as ${TMPDIR:-/tmp}/visor-mint-mac-export.log)" >&2; }
echo "--- Developer ID profiles on disk for $BUNDLE:"
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "\.$BUNDLE<"; then echo "$f"; fi
done
