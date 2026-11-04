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
# Visor Server carries Visor's own Linux programs for the containers it makes
# (docs/co-tenancy.md, "Container images"), in Contents/Resources/Linux,
# signed with it: tools/linux_programs.sh, run in a container leased from
# this Mac's OS Server (`oss machine run container`) of Visor's agent image
# at a build with the Swift its SDK is for (VISOR_LINUX_PROGRAMS_IMAGE names
# another), the SDK and the build kept in a volume of their own.
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

# Visor's own Linux programs, once for every app that carries them.
linux_programs() {
  local oss="/Applications/OS Server.app/Contents/Helpers/oss"
  [ -x "$oss" ] || oss="$(command -v oss)" || { echo "Visor's Linux programs are built in an OS Server container: no oss here" >&2; exit 1; }
  rm -rf dist/linux
  "$oss" machine run container --image="${VISOR_LINUX_PROGRAMS_IMAGE:-ghcr.io/attilathefun/visor-agent:0.43.132}" --cpus=6 --memory=12 \
    --mount="$PWD:$PWD" --volume="visor-linux-programs:/root/.swiftpm:16:keep" --inside -- \
    env VISOR_LINUX_PROGRAMS_SCRATCH=/root/.swiftpm/visor-build "$PWD/tools/linux_programs.sh" "$PWD/dist/linux"
  [ -x dist/linux/visor-server ] && [ -L dist/linux/visor-agent-host ] \
    || { echo "Visor's Linux programs were not built" >&2; exit 1; }
}

# Sends a file for notarization and waits; fails unless Apple accepts it.
notarize() {
  local file="$1" log="$WORK/notary-$(basename "$1").json"
  xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --output-format json >"$log"
  grep -q '"status" *: *"Accepted"' "$log" || { cat "$log" >&2; exit 1; }
}

release_app() {
  local target="$1" name="$2" linux="${3:-}"
  bazel build -c opt "//applications/$target" >/dev/null
  local zip; zip="$(bazel cquery -c opt --output=files "//applications/$target" 2>/dev/null | grep '\.zip$' | head -1)"
  mkdir -p "$WORK/$target"
  ditto -x -k "$zip" "$WORK/$target/"
  local app="$WORK/$target/$name.app"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$VERSION" ] \
    || { echo "$name's CFBundleShortVersionString is not $VERSION" >&2; exit 1; }
  # Visor's Linux programs, sealed with the app (the link kept a link).
  if [ -n "$linux" ]; then
    rm -rf "$app/Contents/Resources/Linux"
    ditto dist/linux "$app/Contents/Resources/Linux"
  fi
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

linux_programs
release_app visor_menubar "Visor Server" linux
release_app visor_macos "Visor"

if [ "$PUBLISH" = "--publish" ]; then
  gh release create "v$VERSION" "dist/Visor-Server-$VERSION.dmg" "dist/Visor-$VERSION.dmg" \
    --title "Visor $VERSION" --notes-file - <<NOTES
Visor $VERSION for the Mac, signed with Developer ID and notarized by Apple.

- **Visor-Server-$VERSION.dmg** — Visor Server, the menu bar app that runs Claude Code, Codex and the openrouter CLI on your Mac and serves them to your devices over any network that reaches your Mac — a LAN, a VPN, a reverse proxy, a tunnel. Needs macOS 15; the agents' CLIs are yours to install.
- **Visor-$VERSION.dmg** — the Visor client for the Mac.

Open the disk image and drag the app to Applications. The iPhone and iPad client is built from source for now (see the README).
NOTES
fi
