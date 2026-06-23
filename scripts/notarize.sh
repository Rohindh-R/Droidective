#!/usr/bin/env bash
# Submit a signed DMG to Apple's notary service, wait for the result, and staple
# the ticket so first launch works offline. Run after package-dmg.sh and before
# publishing/Sparkle-signing (stapling rewrites the DMG).
#
# Requires an App Store Connect API key, passed by path:
#   AC_API_KEY_PATH   path to the AuthKey_XXXX.p8 file
#   AC_API_KEY_ID     the key id
#   AC_API_ISSUER_ID  the issuer id
#
# Usage: notarize.sh <dmg>
set -euo pipefail

DMG="${1:?dmg path required}"
: "${AC_API_KEY_PATH:?AC_API_KEY_PATH (path to .p8) required}"
: "${AC_API_KEY_ID:?AC_API_KEY_ID required}"
: "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID required}"

[[ -f "$DMG" ]] || {
  echo "error: DMG not found: $DMG" >&2
  exit 1
}

echo "Submitting $DMG for notarization (waiting for Apple)…"
xcrun notarytool submit "$DMG" \
  --key "$AC_API_KEY_PATH" \
  --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER_ID" \
  --wait

echo "Stapling notarization ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "notarized + stapled $DMG"
