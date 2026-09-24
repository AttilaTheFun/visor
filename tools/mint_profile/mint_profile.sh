#!/bin/bash
# Mints the free-team development certificate and provisioning profile for
# a bundle id (the phone client's) on a Mac
# that has never signed it: builds a throwaway one-file app with automatic
# signing, so Xcode (signed into the Apple ID, Settings → Accounts) makes
# both. Plug the iPhone in first — free-team profiles embed device UDIDs.
# rules_apple then finds "iOS Team Provisioning Profile: <bundle id>".
#
#   tools/mint_profile/mint_profile.sh <bundle id> <team id> [device UDID]
# (the values in applications/visor_ios/BUILD.bazel)
set -euo pipefail
BUNDLE="${1:?bundle id, as BUNDLE_ID in applications/visor_ios/BUILD.bazel}"
TEAM="${2:?Apple team id, as TEAM_ID in applications/visor_ios/BUILD.bazel}"
DEVICE="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Mint.xcodeproj" "$WORK/Mint"
cp "$HERE/MintProfile/App.swift" "$WORK/Mint/App.swift"
# The project is written here rather than kept: *.xcodeproj is ignored.
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
			CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = $TEAM; PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE;
			PRODUCT_NAME = Mint; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0;
			GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; TARGETED_DEVICE_FAMILY = "1,2";
		}; name = Debug; };
		A000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000C); defaultConfigurationName = Debug; };
		A000000000000000000000C = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos;}; name = Debug; };
		A000000000000000000000D = {isa = PBXProject; buildConfigurationList = A000000000000000000000B; compatibilityVersion = "Xcode 14.0"; mainGroup = A0000000000000000000004; productRefGroup = A0000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (A0000000000000000000008); attributes = {TargetAttributes = {A0000000000000000000008 = {ProvisioningStyle = Automatic;};};}; };
	};
	rootObject = A000000000000000000000D;
}
PBX
DESTINATION="generic/platform=iOS"
[ -n "$DEVICE" ] && DESTINATION="id=$DEVICE"
cd "$WORK"
xcodebuild -project Mint.xcodeproj -scheme Mint -destination "$DESTINATION" -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration build 2>&1 | grep -E "error|Signing Identity|Provisioning Profile|BUILD" || true
echo "--- profiles on disk for $BUNDLE:"
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE<"; then echo "$f"; fi
done
