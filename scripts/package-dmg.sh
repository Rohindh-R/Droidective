#!/usr/bin/env bash
# Ad-hoc sign the built Release app and package it into a drag-to-Applications DMG.
# Assumes the Release configuration has already been built into DerivedData.
set -euo pipefail

VERSION="${1:-dev}"
APP_DIR="DerivedData/Build/Products/Release"
APP="$APP_DIR/Droidective.app"
DMG="$APP_DIR/Droidective-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — build the Release configuration first" >&2
  exit 1
fi

# Re-sign the whole bundle ad-hoc so the signature is internally valid. This
# does not bypass Gatekeeper (no Developer ID) but prevents a broken/missing
# signature from compounding the quarantine "damaged" message.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Stage the app next to an /Applications symlink so the DMG offers drag-install.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$DMG"
hdiutil create -volname "Droidective" -srcfolder "$staging" -ov -format UDZO "$DMG"

echo "created $DMG"
