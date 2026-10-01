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
[ -f "$HOME/.appstoreconnect/visor.env" ] && . "$HOME/.appstoreconnect/visor.env"
AUTH=()
if [ -n "${VISOR_ASC_KEY_PATH:-}" ] && [ -n "${VISOR_ASC_KEY_ID:-}" ] && [ -n "${VISOR_ASC_ISSUER_ID:-}" ]; then
    AUTH=(-authenticationKeyPath "$VISOR_ASC_KEY_PATH" -authenticationKeyID "$VISOR_ASC_KEY_ID" -authenticationKeyIssuerID "$VISOR_ASC_ISSUER_ID")
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Mint.xcodeproj" "$WORK/Mint"
cp "$HERE/MintProfile/App.swift" "$WORK/Mint/App.swift"
cp "$ENTITLEMENTS" "$WORK/Mint/Mint.entitlements"
ENTITLEMENTS_SETTING="CODE_SIGN_ENTITLEMENTS = Mint/Mint.entitlements;"
cat > "$WORK/Mint.xcodeproj/project.pbxproj" <<PBX
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 56;
	objects = {
		A0000000000000000000001 = {isa = PBXBuildFile; fileRef = A0000000000000000000002; };
		A0000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
		A0000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Mint.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A0000000000000000000004 = {isa = PBXGroup; children = (A0000000000000000000005, A0000000000000000000006); sourceTree = "<group>"; };
		A0000000000000000000005 = {isa = PBXGroup; children = (A0000000000000000000002); path = Mint; sourceTree = "<group>"; };
		A0000000000000000000006 = {isa = PBXGroup; children = (A0000000000000000000003); name = Products; sourceTree = "<group>"; };
		A0000000000000000000007 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A0000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		A0000000000000000000008 = {isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000009; buildPhases = (A0000000000000000000007); buildRules = (); dependencies = (); name = Mint; productName = Mint; productReference = A0000000000000000000003; productType = "com.apple.product-type.application"; };
		A0000000000000000000009 = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000A); defaultConfigurationName = Debug; };
		A000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {
			CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = $TEAM; PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE; $ENTITLEMENTS_SETTING
			PRODUCT_NAME = Mint; SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0;
			GENERATE_INFOPLIST_FILE = YES; ENABLE_HARDENED_RUNTIME = YES;
		}; name = Debug; };
		A000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000C); defaultConfigurationName = Debug; };
		A000000000000000000000C = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx;}; name = Debug; };
		A000000000000000000000D = {isa = PBXProject; buildConfigurationList = A000000000000000000000B; compatibilityVersion = "Xcode 14.0"; mainGroup = A0000000000000000000004; productRefGroup = A0000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (A0000000000000000000008); attributes = {TargetAttributes = {A0000000000000000000008 = {ProvisioningStyle = Automatic;};};}; };
	};
	rootObject = A000000000000000000000D;
}
PBX
cd "$WORK"
xcodebuild -project Mint.xcodeproj -scheme Mint -configuration Debug -archivePath "$WORK/Mint.xcarchive" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive 2>&1 | grep -E "error|BUILD|ARCHIVE" || true
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
xcodebuild -exportArchive -archivePath "$WORK/Mint.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
    -exportPath "$WORK/out" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} 2>&1 | grep -E "error|EXPORT" || true
echo "--- Developer ID profiles on disk for $BUNDLE:"
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "\.$BUNDLE<"; then echo "$f"; fi
done
