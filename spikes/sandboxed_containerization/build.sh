#!/bin/sh
# Build the spike app, ad hoc, sandboxed. GROUPS_EXTRA=1 also claims group.com.LoganShire.VisorSpike.
set -eu
cd "$(dirname "$0")"
TEAM="${SPIKE_TEAM:-$(cat team.txt)}"  # your team id (team.txt is not committed)
swift build -c release 2>&1 | tail -5
APP="$HOME/Applications/VisorSandboxSpike.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/VisorSandboxSpike "$APP/Contents/MacOS/"
sed "s/@TEAM@/$TEAM/" Info.plist.in > "$APP/Contents/Info.plist"
extra=""
[ "${GROUPS_EXTRA:-0}" = 1 ] && extra="<string>group.com.LoganShire.VisorSpike</string>"
sed -e "s/@TEAM@/$TEAM/" -e "s#@GROUPS@#$extra#" spike.entitlements.in > spike.entitlements
codesign --force --sign - --entitlements spike.entitlements --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo built "$APP"
