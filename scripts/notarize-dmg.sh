#!/usr/bin/env bash
# Sign a Developer ID DMG, submit it to Apple's notary service, and staple the
# resulting ticket so it passes Gatekeeper on download (no quarantine prompt).
#
# The app inside must already be Developer-ID-signed with the hardened runtime
# (scripts/package-dmg.sh with SIGN_IDENTITY set does this).
#
# Usage:
#   notarize-dmg.sh <dmg>
#
# Required environment (App Store Connect API key auth):
#   SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"
#   NOTARY_KEY_PATH   path to the .p8 API key file
#   NOTARY_KEY_ID     the key's Key ID
#   NOTARY_ISSUER_ID  the App Store Connect issuer UUID
set -euo pipefail

DMG="${1:?dmg path required}"
: "${SIGN_IDENTITY:?Developer ID identity required (SIGN_IDENTITY)}"
: "${NOTARY_KEY_PATH:?API key path required (NOTARY_KEY_PATH)}"
: "${NOTARY_KEY_ID:?key id required (NOTARY_KEY_ID)}"
: "${NOTARY_ISSUER_ID:?issuer id required (NOTARY_ISSUER_ID)}"

[[ -f "$DMG" ]] || {
  echo "error: DMG not found: $DMG" >&2
  exit 1
}

# Sign the disk image itself so Gatekeeper trusts the container, then notarize.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "notarized + stapled $DMG"
