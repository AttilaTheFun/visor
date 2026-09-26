#!/bin/bash
# Builds the Mac apps for anyone to install, and optionally publishes them:
# Visor Server and the Visor client, each signed with the builder's
# "Developer ID Application" certificate, notarized by Apple and stapled,
# in a disk image. Xcode does the signing and the notarizing (it must be
# signed into the team's account, Settings → Accounts); the team is
# VISOR_TEAM_ID in .bazelrc.user.
#
#   tools/release_mac.sh <version>               # the .dmgs in dist/
#   tools/release_mac.sh <version> --publish     # and a GitHub release v<version>
set -euo pipefail
VERSION="${1:?version, e.g. 0.1}"
PUBLISH="${2:-}"
cd "$(dirname "$0")/.."
TEAM="$(sed -n 's/.*VISOR_TEAM_ID=\([A-Z0-9]*\).*/\1/p' .bazelrc.user 2>/dev/null | head -1)"
[ -n "$TEAM" ] || { echo "No VISOR_TEAM_ID in .bazelrc.user (tools/signing)" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" \
  || { echo "No Developer ID Application certificate for the team in the keychain (Xcode → Settings → Accounts → Manage Certificates)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p dist

release_app() {
  local target="$1" name="$2"
  bazel build -c opt "//applications/$target" >/dev/null
  local zip; zip="$(bazel cquery -c opt --output=files "//applications/$target" 2>/dev/null | grep '\.zip$' | head -1)"
  local archive="$WORK/$target.xcarchive"
  mkdir -p "$archive/Products/Applications"
  ditto -x -k "$zip" "$archive/Products/Applications/"
  local app="$archive/Products/Applications/$name.app"
  local plist="$app/Contents/Info.plist"
  local bundle; bundle="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = "$VERSION" ] \
    || { echo "$name's CFBundleShortVersionString is not $VERSION" >&2; exit 1; }
  # An archive as Xcode would make it, so Xcode can export it.
  cat > "$archive/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/$name.app</string>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>SigningIdentity</key><string>-</string>
<key>Team</key><string>$TEAM</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
<key>Name</key><string>$name</string>
<key>SchemeName</key><string>$name</string>
</dict></plist>
PLIST
  cat > "$WORK/$target-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>destination</key><string>upload</string>
</dict></plist>
PLIST
  echo "$name: signing and sending for notarization…"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$WORK/$target-options.plist" \
    -exportPath "$WORK/$target-upload" -allowProvisioningUpdates >"$WORK/$target-upload.log" 2>&1 \
    || { tail -20 "$WORK/$target-upload.log" >&2; exit 1; }
  # Notarized and stapled: Apple takes a few minutes.
  local out="$WORK/$target-notarized"
  for _ in $(seq 1 90); do
    if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$out" >"$WORK/$target-notarized.log" 2>&1; then break; fi
    sleep 20
  done
  [ -d "$out/$name.app" ] || { tail -20 "$WORK/$target-notarized.log" >&2; exit 1; }
  xcrun stapler validate "$out/$name.app" >/dev/null
  spctl --assess --type execute "$out/$name.app"
  # The disk image: the app and a link to Applications, to drag it onto.
  local stage="$WORK/$target-dmg"
  mkdir -p "$stage"
  cp -R "$out/$name.app" "$stage/"
  ln -s /Applications "$stage/Applications"
  local dmg="dist/$(echo "$name" | tr ' ' '-')-$VERSION.dmg"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$name" -srcfolder "$stage" -format UDZO "$dmg"
  echo "$name: $dmg"
}

release_app visor_menubar "Visor Server"
release_app visor_macos "Visor"

if [ "$PUBLISH" = "--publish" ]; then
  gh release create "v$VERSION" "dist/Visor-Server-$VERSION.dmg" "dist/Visor-$VERSION.dmg" \
    --title "Visor $VERSION" --notes-file - <<NOTES
Visor $VERSION for the Mac, signed with Developer ID and notarized by Apple.

- **Visor-Server-$VERSION.dmg** — Visor Server, the menu bar app that runs Claude Code, Codex and the openrouter CLI on your Mac and serves them to your devices over Tailscale. Needs macOS 15 and Tailscale with HTTPS certificates enabled; the agents' CLIs are yours to install.
- **Visor-$VERSION.dmg** — the Visor client for the Mac.

Open the disk image and drag the app to Applications. The iPhone and iPad client is built from source for now (see the README).
NOTES
fi
