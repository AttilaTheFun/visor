# What the two profile-minting scripts share. Sourced, not run.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# xcodebuild's sign-in: the App Store Connect API key in the environment or
# in ~/.appstoreconnect/visor.env (local to the Mac; never in a repository),
# else Xcode's own account. Sets AUTH.
mint_auth() {
  [ -f "$HOME/.appstoreconnect/visor.env" ] && . "$HOME/.appstoreconnect/visor.env"
  AUTH=()
  if [ -n "${VISOR_ASC_KEY_PATH:-}" ] && [ -n "${VISOR_ASC_KEY_ID:-}" ] && [ -n "${VISOR_ASC_ISSUER_ID:-}" ]; then
    AUTH=(-authenticationKeyPath "$VISOR_ASC_KEY_PATH" -authenticationKeyID "$VISOR_ASC_KEY_ID" -authenticationKeyIssuerID "$VISOR_ASC_ISSUER_ID")
  fi
}

# A throwaway one-file app with automatic signing, in <work>: the project is
# written here rather than kept (*.xcodeproj is ignored).
#   mint_project <work> <team> <bundle id> ios|macos|tvos [entitlements file]
mint_project() {
  local work="$1" team="$2" bundle="$3" platform="$4" entitlements="${5:-}"
  local here settings sdk entitlements_setting=""
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$work/Mint.xcodeproj" "$work/Mint"
  cp "$here/MintProfile/App.swift" "$work/Mint/App.swift"
  if [ -n "$entitlements" ]; then
    cp "$entitlements" "$work/Mint/Mint.entitlements"
    entitlements_setting="CODE_SIGN_ENTITLEMENTS = Mint/Mint.entitlements;"
  fi
  if [ "$platform" = macos ]; then
    sdk=macosx
    settings="SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0;
			GENERATE_INFOPLIST_FILE = YES; ENABLE_HARDENED_RUNTIME = YES;"
  elif [ "$platform" = tvos ]; then
    sdk=appletvos
    settings="SDKROOT = appletvos; TVOS_DEPLOYMENT_TARGET = 18.0; SWIFT_VERSION = 5.0;
			GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; TARGETED_DEVICE_FAMILY = 3;"
  else
    sdk=iphoneos
    settings="SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0;
			GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; TARGETED_DEVICE_FAMILY = \"1,2\";"
  fi
  cat > "$work/Mint.xcodeproj/project.pbxproj" <<PBX
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
			CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = $team; PRODUCT_BUNDLE_IDENTIFIER = $bundle; $entitlements_setting
			PRODUCT_NAME = Mint; $settings
		}; name = Debug; };
		A000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (A000000000000000000000C); defaultConfigurationName = Debug; };
		A000000000000000000000C = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = $sdk;}; name = Debug; };
		A000000000000000000000D = {isa = PBXProject; buildConfigurationList = A000000000000000000000B; compatibilityVersion = "Xcode 14.0"; mainGroup = A0000000000000000000004; productRefGroup = A0000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (A0000000000000000000008); attributes = {TargetAttributes = {A0000000000000000000008 = {ProvisioningStyle = Automatic;};};}; };
	};
	rootObject = A000000000000000000000D;
}
PBX
}
