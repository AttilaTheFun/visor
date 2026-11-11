#!/bin/bash
# The iPhone's part of the proof (ci.yml's verify), on one of
# GitHub's own Macs (`xcode-27`): the app and its probe (tests/ios_probe),
# built on Linux by the proof's build job for Apple silicon's simulator,
# run as Shireworks runs them on an iOS lease, which is rules_apple's runner
# (apple/testing/default_runner/ios_xctestrun_runner.template.sh): an
# XCTRunner app made from Xcode's with the probe in it, an .xctestrun, then
# `xcodebuild test-without-building`. On an iPhone 17 of iOS 27.2 (the
# runtime the pictures it is compared with were taken on: GitHub rolls a
# new image out over days, and its runners' older one had iOS 27.0 alone,
# whose pictures differ in most screens; downloaded where the image hasn't
# got it), made for the run, its status bar held still and keyboard
# suggestions off, it runs the fixture's screens in portrait and on its side
# (the probe's testFixtureScreens and testFixtureScreensLandscape) and, for
# a full proof, its UI cases (tools/ios_ui_tests.sh's). A test that fails is
# run once more (GitHub's Macs vary in speed: a UI case's timing, an app
# that didn't launch), and fails the proof only if it fails again. The
# pictures come out of the runs' result bundles, where the probe attaches
# each (from the last repetition that took it).
#
#   tools/ci/proof_ios.sh <apps> <out> [quick|full]
#
# <apps> holds visor_ios.ipa and visor_probe.zip. Out come
# <out>/screens/ios-<screen>.png and ios-<screen>-landscape.png,
# <out>/logs/ (each run's xcodebuild log and result bundle, zipped), and
# <out>/device.txt (the simulator and Xcode, for the proof's summary).
#
#   DEVELOPER_DIR      the Xcode (default: Xcode 27.2, the SDK the apps are
#                      built with, where the image has it; else its default)
#   PROOF_IOS_VERSION  the simulator's iOS (default: 27.2)
#
# Fails as the probe does (a full proof's UI cases too), after every run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_ios.sh <apps> <out> [quick|full]" >&2; exit 2; }
[ $# -ge 2 ] || usage
apps="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
kind="${3:-full}"
case "$kind" in quick | full) ;; *) usage ;; esac
DEVICE="iPhone 17"
UI_CASES="$(sed -n 's/^CASES="\${VISOR_UI_CASES:-\(.*\)}"$/\1/p' "$ROOT/tools/ios_ui_tests.sh")"
[ -n "$UI_CASES" ] || { echo "$me: no UI cases in tools/ios_ui_tests.sh" >&2; exit 1; }
for file in visor_ios.ipa visor_probe.zip; do
    [ -f "$apps/$file" ] || { echo "$me: no $file in $apps" >&2; exit 1; }
done
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
platform="$developer/Platforms/iPhoneSimulator.platform/Developer"

work="$(mktemp -d)"
udid=""
finished=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" 2> /dev/null || true
        xcrun simctl delete "$udid" 2> /dev/null || true
    fi
    chmod -R u+w "$work" 2> /dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

echo "::group::An $DEVICE"
# The runtime of that iOS that runs the device (a runtime that came with a
# new phone runs that phone alone: xcode-27's iOS 27.1, the iPhone Duo; its
# iOS 27.2 has one for the iPhone 19 beside the one for the rest).
IOS_VERSION="${PROOF_IOS_VERSION:-27.2}"
pick_runtime() {
    xcrun simctl list runtimes --json | python3 -I -c '
import json, sys
device, version = sys.argv[1:3]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")
            and (r["version"] == version or r["version"].startswith(version + "."))
            and any(t.get("name") == device for t in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(runtimes[-1]["identifier"] + " " + runtimes[-1]["version"] + " (" + runtimes[-1].get("buildversion", "?") + ")" if runtimes else "")' "$DEVICE" "$IOS_VERSION"
}
runtime="$(pick_runtime)"
if [ -z "$runtime" ]; then
    echo "::warning::This image has no iOS $IOS_VERSION simulator that runs an $DEVICE: downloading it"
    mkdir -p "$out/logs"
    xcodebuild -downloadPlatform iOS -buildVersion "$IOS_VERSION" > "$out/logs/download-platform.log" 2>&1 \
        || tail -20 "$out/logs/download-platform.log"
    # Listed a little after it is installed, once CoreSimulator has mounted it.
    for _ in $(seq 1 24); do
        runtime="$(pick_runtime)"
        [ -z "$runtime" ] || break
        sleep 5
    done
fi
[ -n "$runtime" ] || { echo "::error::No iOS $IOS_VERSION simulator that runs an $DEVICE on this runner: its pictures would not compare with the base's"; exit 1; }
version="${runtime#* }"
runtime="${runtime%% *}"
udid="$(xcrun simctl create "Visor proof" "$DEVICE" "$runtime")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b > /dev/null
# The status bar as Shireworks holds a lease's: 9:41 on a fixed day (an
# older simctl takes the time alone), full Wi-Fi and signal, a full
# battery, no carrier. No keyboard suggestions over the keys: what they say
# is learned and comes in late.
bar=(--dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4
     --operatorName "" --batteryState charged --batteryLevel 100)
still="$(python3 -I -c 'import datetime; print(datetime.datetime(2007, 1, 9, 9, 41).astimezone().isoformat(timespec="milliseconds"))')"
xcrun simctl status_bar "$udid" override --time "$still" "${bar[@]}" 2> /dev/null \
    || xcrun simctl status_bar "$udid" override --time 9:41 "${bar[@]}"
xcrun simctl spawn "$udid" defaults write com.apple.Preferences KeyboardPrediction -bool NO
xcode="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
printf '%s, iOS %s, %s\n' "$DEVICE" "$version" "$xcode" | tee "$out/device.txt"
echo "::endgroup::"

# A run's folder as rules_apple's runner makes its test folder: the probe
# and its host unpacked, writable, the probe in an XCTRunner app of its
# own, the .xctestrun beside them (as Shireworks' XCTestFolder.prepare).
prepare() {
    local folder=$1
    mkdir -p "$folder/unpack"
    ditto -x -k "$apps/visor_probe.zip" "$folder/unpack/tests"
    ditto -x -k "$apps/visor_ios.ipa" "$folder/unpack/host"
    chmod -R u+w "$folder/unpack"
    python3 -I - "$folder" "$platform" "$developer" << 'PY'
import os, plistlib, shutil, sys
folder, platform, developer = sys.argv[1:4]

def writable(path):
    # Xcode's own files are read-only, and so are their copies: the runner's
    # Info.plist is written, xcodebuild writes into the bundles.
    for directory, folders, files in os.walk(path):
        for name in [directory] + [os.path.join(directory, item) for item in folders + files]:
            if not os.path.islink(name):
                os.chmod(name, os.stat(name).st_mode | 0o200)

def one(directory, kind):
    found = [name for name in os.listdir(directory) if name.endswith("." + kind)]
    if len(found) != 1:
        sys.exit(f"proof_ios: {len(found)} .{kind} in {directory}, not one")
    return found[0][: -len(kind) - 1]

bundle = one(f"{folder}/unpack/tests", "xctest")
host = one(f"{folder}/unpack/host/Payload", "app")
os.rename(f"{folder}/unpack/host/Payload/{host}.app", f"{folder}/{host}.app")

# The runner: Xcode's XCTRunner.app as <bundle>-Runner.app, the probe in its
# PlugIns, XCTest's frameworks in its Frameworks, its Info.plist named and
# identified as this probe's runner.
library = f"{platform}/Library"
runner = f"{folder}/{bundle}-Runner.app"
identifier = f"com.apple.test.{bundle}-Runner"
shutil.copytree(f"{library}/Xcode/Agents/XCTRunner.app", runner, symlinks=True)
writable(runner)
os.makedirs(f"{runner}/PlugIns")
plugged = f"{runner}/PlugIns/{bundle}.xctest"
os.rename(f"{folder}/unpack/tests/{bundle}.xctest", plugged)
os.makedirs(f"{plugged}/Frameworks", exist_ok=True)
with open(f"{plugged}/Info.plist", "rb") as file:
    info = plistlib.load(file)
os.utime(f"{plugged}/{info.get('CFBundleExecutable', bundle)}")
replacements = [("$(WRAPPEDPRODUCTNAME)", "XCTRunner"), ("WRAPPEDPRODUCTNAME", "XCTRunner"),
                ("$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)", identifier), ("WRAPPEDPRODUCTBUNDLEIDENTIFIER", identifier)]
def substitute(value):
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [substitute(item) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item) for key, item in value.items()}
    return value
with open(f"{runner}/Info.plist", "rb") as file:
    runner_info = plistlib.load(file)
with open(f"{runner}/Info.plist", "wb") as file:
    plistlib.dump(substitute(runner_info), file, fmt=plistlib.FMT_BINARY)
os.makedirs(f"{runner}/Frameworks", exist_ok=True)
automation = f"{library}/Frameworks/XCUIAutomation.framework"
if not os.path.exists(automation):
    automation = f"{library}/PrivateFrameworks/XCUIAutomation.framework"
for source, required in [(f"{library}/Frameworks/XCTest.framework", True),
                         (f"{library}/PrivateFrameworks/XCTestCore.framework", True),
                         (f"{library}/PrivateFrameworks/XCTAutomationSupport.framework", True),
                         (f"{library}/PrivateFrameworks/XCUnit.framework", False),
                         (f"{platform}/usr/lib/libXCTestSwiftSupport.dylib", True),
                         (f"{platform}/usr/lib/libXCTestBundleInject.dylib", True),
                         (f"{library}/PrivateFrameworks/XCTestSupport.framework", False),
                         (f"{library}/Frameworks/Testing.framework", False),
                         (automation, True)]:
    if not os.path.exists(source):
        if required:
            sys.exit(f"proof_ios: this Xcode has no {source} for the probe's runner")
        continue
    target = f"{runner}/Frameworks/{os.path.basename(source)}"
    (shutil.copytree(source, target, symlinks=True) if os.path.isdir(source) else shutil.copy2(source, target))
writable(runner)

# The .xctestrun, as rules_apple's runner fills its template for a UI test.
libraries = "__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib"
bundle_path = f"__TESTHOST__/PlugIns/{bundle}.xctest"
target_app = f"__TESTROOT__/{host}.app"
environment = {"DYLD_INSERT_LIBRARIES": "", "DYLD_LIBRARY_PATH": libraries,
               "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/DUMMY_SRCROOT/",
               "XCInjectBundleInto": f"__TESTHOST__/{host}.app/{host}"}
if os.path.exists(f"{library}/Frameworks/Testing.framework"):
    environment["DYLD_FRAMEWORK_PATH"] = f"{developer}/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
target = bundle.replace("-", "_")
test = {"ProductModuleName": target, "TestBundlePath": bundle_path, "TestExecutionOrdering": "ordered",
        "IsAppHostedTestBundle": True, "TestHostPath": f"__TESTROOT__/{bundle}-Runner.app",
        "TestHostBundleIdentifier": identifier, "IsUITestBundle": True, "IsXCTRunnerHostedTestBundle": True,
        "UITargetAppPath": target_app, "DependentProductPaths": [bundle_path, target_app, f"__TESTROOT__/{bundle}-Runner.app"],
        "TestingEnvironmentVariables": environment, "SystemAttachmentLifetime": "keepNever",
        "UserAttachmentLifetime": "keepNever", "ClangProfileDataDirectoryPath": folder}
coverage = {"Architecture": "arm64", "BuildableIdentifier": "000000000000000000000000:primary", "IncludeInReport": True,
            "IsStatic": False, "Name": f"{bundle}.xctest", "ProductPath": bundle_path,
            "Toolchains": ["com.apple.dt.toolchain.XcodeDefault"]}
with open(f"{folder}/tests.xctestrun", "wb") as file:
    plistlib.dump({target: test, "__xctestrun_metadata__": {"CodeCoverageBuildableInfos": [coverage], "FormatVersion": 1}}, file)
with open(f"{folder}/target", "w") as file:
    file.write(target)
PY
}

# Each run in a folder of its own, whatever the one before did: the
# fixture's screens in each orientation, then a full proof's UI cases.
status=0
mkdir -p "$out/logs" "$out/screens"
xctest() {
    local name=$1 folder="$work/$1"
    shift
    echo "::group::$name"
    prepare "$folder"
    local target only=()
    target="$(cat "$folder/target")"
    for test in "$@"; do
        case "$test" in "$target" | "$target"/*) only+=("-only-testing:$test") ;; *) only+=("-only-testing:$target/$test") ;; esac
    done
    local result=0
    # A failed test is tried up to three times: GitHub's simulators are
    # slow some days, and on 11 Nov four release runs each failed a
    # different probe (a 0.5 s timing, a UI query timing out, "Failed to
    # terminate com.LoganShire.Visor") that passed on the run before. A
    # failure that repeats three times is still the proof's.
    xcodebuild test-without-building -xctestrun "$folder/tests.xctestrun" -destination "id=$udid" \
        -resultBundlePath "$folder/result.xcresult" -derivedDataPath "$folder/derived_data" \
        -collect-test-diagnostics never -retry-tests-on-failure -test-iterations 3 \
        "${only[@]}" > "$out/logs/$name.log" 2>&1 || result=$?
    grep -E '^(Test Suite|Test Case .*(passed|failed)|.*error:|\*\* TEST)' "$out/logs/$name.log" | tail -40 || true
    if [ "$result" -ne 0 ]; then
        echo "::error::$name failed ($result)"
        tail -60 "$out/logs/$name.log"
        status=1
    fi
    [ ! -d "$folder/result.xcresult" ] || ditto -c -k --keepParent "$folder/result.xcresult" "$out/logs/$name.xcresult.zip"
    echo "::endgroup::"
}
xctest portrait VisorProbe/testFixtureScreens
xctest landscape VisorProbe/testFixtureScreensLandscape
if [ "$kind" = full ]; then
    IFS=, read -r -a cases <<< "$UI_CASES"
    xctest ui-cases "${cases[@]}"
fi

# The pictures named fixture-<screen> out of each orientation's result
# bundle: ios-<screen>.png, and ios-<screen>-landscape.png.
for orientation in portrait landscape; do
    bundle="$work/$orientation/result.xcresult"
    [ -d "$bundle" ] || { echo "$me: the $orientation run left no result bundle" >&2; status=1; continue; }
    mkdir -p "$work/attachments-$orientation"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$work/attachments-$orientation" > /dev/null
    suffix=""
    [ "$orientation" = portrait ] || suffix="-landscape"
    python3 -I - "$work/attachments-$orientation" "$out/screens" "$suffix" << 'PY'
import json, os, re, shutil, sys
source, out, suffix = sys.argv[1:4]
with open(os.path.join(source, "manifest.json")) as file:
    manifest = json.load(file)
# Each screen from the last repetition that took it: a test run again after
# a failure attaches its pictures again.
chosen = {}
for test in manifest:
    for attachment in test.get("attachments", []):
        # The attachment's name as the probe gave it, which xcresulttool
        # suffixes with an index and an identifier.
        name = attachment.get("suggestedHumanReadableName", "")
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", name)
        if name.startswith("fixture-") and name.endswith(".png"):
            repetition = attachment.get("repetitionNumber") or 0
            if name not in chosen or repetition >= chosen[name][0]:
                chosen[name] = (repetition, attachment["exportedFileName"])
for name, (_, exported) in chosen.items():
    screen = name[len("fixture-"):-len(".png")]
    shutil.copy(os.path.join(source, exported), os.path.join(out, f"ios-{screen}{suffix}.png"))
PY
done
count="$(find "$out/screens" -name 'ios-*.png' | wc -l | tr -d ' ')"
echo "$count iPhone screens"
[ "$count" -gt 0 ] || { echo "$me: no screens came back in the result bundles" >&2; status=1; }
finished=1
exit "$status"
