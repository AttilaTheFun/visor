#!/bin/bash
# Stores the notarization credentials tools/release_mac.sh uses, in a
# keychain of their own: ~/Library/Keychains/visor-notary.keychain-db, apart
# from the login keychain, never locking by itself. Its password is kept in
# ~/.visor/notary-keychain-password (readable only by you), so the release
# unlocks it without asking. Run it in a terminal; notarytool asks for the
# app-specific password (appleid.apple.com → Sign-In and Security →
# App-Specific Passwords). Run it again whenever the profile goes missing or
# the password changes.
#
#   tools/store_notary_credentials.sh <Apple ID email>
#
# The team is VISOR_TEAM_ID in .bazelrc.user; VISOR_NOTARY_PROFILE names a
# profile other than visor-notary.
set -euo pipefail
APPLE_ID="${1:?your Apple ID email}"
PROFILE="${VISOR_NOTARY_PROFILE:-visor-notary}"
KEYCHAIN="$HOME/Library/Keychains/visor-notary.keychain-db"
PASSFILE="$HOME/.visor/notary-keychain-password"
cd "$(dirname "$0")/.."
TEAM="$(sed -n 's/.*VISOR_TEAM_ID=\([A-Z0-9]*\).*/\1/p' .bazelrc.user 2>/dev/null | head -1)"
[ -n "$TEAM" ] || { echo "No VISOR_TEAM_ID in .bazelrc.user (tools/signing)" >&2; exit 1; }

if [ ! -s "$PASSFILE" ]; then
  mkdir -p "$(dirname "$PASSFILE")"
  chmod 700 "$(dirname "$PASSFILE")"
  (umask 077; openssl rand -base64 24 >"$PASSFILE")
fi
if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
fi
security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
# No lock after a timeout or on sleep.
security set-keychain-settings "$KEYCHAIN"

xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM" --keychain "$KEYCHAIN"
xcrun notarytool history --keychain-profile "$PROFILE" --keychain "$KEYCHAIN" >/dev/null
echo "Stored \"$PROFILE\" in $KEYCHAIN; tools/release_mac.sh uses it."
