#!/bin/bash
# Builds the Mac apps for anyone to install, and optionally publishes them:
# Visor Server and the Visor client, each signed with the builder's
# "Developer ID Application" certificate (tools/sign_mac_app.sh), notarized
# by Apple and stapled, in a disk image that is signed, notarized and
# stapled too. Notarization uses a notarytool keychain profile, stored once
# in a keychain of its own by
#
#   tools/store_notary_credentials.sh <Apple ID email>
#
# (an app-specific password; VISOR_NOTARY_PROFILE names another profile).
# Without that keychain, the profile is looked for in the login keychain.
# The team is VISOR_TEAM_ID in .bazelrc.user. Xcode's sign-in is not needed.
#
#   tools/release_mac.sh <version>               # the .dmgs in dist/
#   tools/release_mac.sh <version> --publish     # and a GitHub release v<version>
set -euo pipefail
VERSION="${1:?version, e.g. 0.1}"
PUBLISH="${2:-}"
PROFILE="${VISOR_NOTARY_PROFILE:-visor-notary}"
cd "$(dirname "$0")/.."
. tools/lib.sh
TEAM="$(visor_team)"
IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\([0-9A-F]\{40\}\) \"Developer ID Application: .*($TEAM)\"/\1/p" | head -1)"
[ -n "$IDENTITY" ] \
  || { echo "No Developer ID Application certificate for the team in the keychain (Xcode → Settings → Accounts → Manage Certificates)" >&2; exit 1; }
KEYCHAIN="$HOME/Library/Keychains/visor-notary.keychain-db"
PASSFILE="$HOME/.visor/notary-keychain-password"
NOTARY=(--keychain-profile "$PROFILE")
if [ -f "$KEYCHAIN" ] && [ -s "$PASSFILE" ]; then
  visor_keychain unlock-keychain "$PASSFILE" "$KEYCHAIN"
  NOTARY+=(--keychain "$KEYCHAIN")
fi
xcrun notarytool history "${NOTARY[@]}" >/dev/null 2>&1 \
  || { echo "No notarytool profile \"$PROFILE\": run tools/store_notary_credentials.sh <Apple ID email>" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p dist

# Sends a file for notarization and waits; fails unless Apple accepts it.
notarize() {
  local file="$1" log="$WORK/notary-$(basename "$1").json"
  xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --output-format json >"$log"
  grep -q '"status" *: *"Accepted"' "$log" || { cat "$log" >&2; exit 1; }
}

release_app() {
  local target="$1" name="$2"
  bazel build -c opt "//applications/$target" >/dev/null
  local zip; zip="$(bazel cquery -c opt --output=files "//applications/$target" 2>/dev/null | grep '\.zip$' | head -1)"
  mkdir -p "$WORK/$target"
  ditto -x -k "$zip" "$WORK/$target/"
  local app="$WORK/$target/$name.app"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$VERSION" ] \
    || { echo "$name's CFBundleShortVersionString is not $VERSION" >&2; exit 1; }
  tools/sign_mac_app.sh "$app" >/dev/null
  local signature; signature="$(codesign -dvv "$app" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application"* ]] \
    || { echo "$name was not signed with Developer ID" >&2; exit 1; }
  echo "$name: notarizing the app…"
  ditto -c -k --keepParent "$app" "$WORK/$target.zip"
  notarize "$WORK/$target.zip"
  xcrun stapler staple -q "$app"
  spctl --assess --type execute "$app"
  # The disk image: the app and a link to Applications, to drag it onto;
  # signed and notarized in its own right, so the download checks out too.
  local stage="$WORK/$target-dmg"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  local dmg="dist/$(echo "$name" | tr ' ' '-')-$VERSION.dmg"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$name" -srcfolder "$stage" -format UDZO "$dmg"
  codesign --sign "$IDENTITY" --timestamp "$dmg"
  echo "$name: notarizing the disk image…"
  notarize "$dmg"
  xcrun stapler staple -q "$dmg"
  spctl --assess --type open --context context:primary-signature "$dmg"
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
