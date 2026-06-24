#!/usr/bin/env bash
# Sign the built Release app and package it into a drag-to-Applications DMG.
# Assumes the Release app is already built and scripts/bundle-tools.sh has
# injected scrcpy/ffmpeg.
#
# Signing identity comes from $SIGN_IDENTITY (default "-" = ad-hoc, for local
# dev). A real "Developer ID Application: …" identity additionally enables the
# hardened runtime + secure timestamp, which notarization requires.
set -euo pipefail

VERSION="${1:-dev}"
APP_DIR="DerivedData/Build/Products/Release"
APP="$APP_DIR/Droidective.app"
DMG="$APP_DIR/Droidective-${VERSION}.dmg"
IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — build the Release configuration first" >&2
  exit 1
fi

opts=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  opts+=(--options runtime --timestamp)
fi

# Sparkle ships nested helpers (Autoupdate, Updater.app, the Downloader/Installer
# XPC services) that xcodebuild leaves with their upstream signatures — no
# Developer ID and no secure timestamp — which notarization rejects. Re-sign each
# (preserving its entitlements), then re-seal the framework.
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
  for version in "$sparkle"/Versions/[A-Z]; do
    [[ -d "$version" ]] || continue
    for nested in \
      "$version/XPCServices/Downloader.xpc" \
      "$version/XPCServices/Installer.xpc" \
      "$version/Autoupdate" \
      "$version/Updater.app"; do
      [[ -e "$nested" ]] && codesign "${opts[@]}" --preserve-metadata=entitlements "$nested"
    done
  done
  codesign "${opts[@]}" "$sparkle"
fi

# bundle-tools added loose dylibs and helper executables after xcodebuild signed
# the app, so re-sign those too, then re-seal the whole bundle.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  for lib in "$APP/Contents/Frameworks"/*.dylib; do
    [[ -f "$lib" ]] && codesign "${opts[@]}" "$lib"
  done
fi
if [[ -d "$APP/Contents/Helpers" ]]; then
  for helper in "$APP/Contents/Helpers"/*; do
    [[ -f "$helper" ]] && codesign "${opts[@]}" "$helper"
  done
fi
codesign "${opts[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# Stage the app next to an /Applications symlink so the DMG offers drag-install.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$DMG"
hdiutil create -volname "Droidective" -srcfolder "$staging" -ov -format UDZO "$DMG"

# Sign the DMG itself so the download carries a Developer ID signature too.
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

echo "created $DMG (identity: $IDENTITY)"
