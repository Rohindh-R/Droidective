#!/usr/bin/env bash
# Sign the built Release app and package it into a drag-to-Applications DMG.
# Assumes the Release configuration has already been built into DerivedData.
#
# Signing identity comes from $SIGN_IDENTITY:
#   "-" (default)               ad-hoc — local dev, not notarizable.
#   "Developer ID Application…"  Developer ID — hardened runtime + secure
#                               timestamp, ready for notarization (see
#                               scripts/notarize-dmg.sh).
set -euo pipefail

VERSION="${1:-dev}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_DIR="DerivedData/Build/Products/Release"
APP="$APP_DIR/Droidective.app"
DMG="$APP_DIR/Droidective-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — build the Release configuration first" >&2
  exit 1
fi

# Sign the bundled command-line binaries first (codesign --deep doesn't reliably
# sign loose Mach-O executables sitting in Resources), then sign the whole
# bundle. ffmpeg is the only macOS Mach-O — scrcpy-server is a device-side
# payload covered by the bundle seal. Ad-hoc keeps the signature internally
# valid; Developer ID adds the hardened runtime and a secure timestamp so the
# bundle can be notarized.
sign() {
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$@"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"
  fi
}

ffmpeg="$APP/Contents/Resources/ffmpeg"
[[ -f "$ffmpeg" ]] && sign "$ffmpeg"
sign --deep "$APP"
codesign --verify --deep --strict "$APP"

# Stage the app next to an /Applications symlink so the DMG offers drag-install.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$DMG"
hdiutil create -volname "Droidective" -srcfolder "$staging" -ov -format UDZO "$DMG"

echo "created $DMG"
