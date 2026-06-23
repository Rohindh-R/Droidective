#!/usr/bin/env bash
# Vendor scrcpy + ffmpeg (and scrcpy's server) into the built .app so the
# release DMG is self-contained — users don't need Homebrew. adb and the Android
# emulator are NOT bundled (Android SDK licensing forbids redistribution); the
# app resolves the user's own SDK copies for those.
#
# Run AFTER xcodebuild and BEFORE signing: this adds Contents/Helpers and loose
# dylibs to Contents/Frameworks, which invalidates the app signature, so
# package-dmg.sh re-signs everything afterward.
#
# Usage: bundle-tools.sh [path/to/Droidective.app]
set -euo pipefail

APP="${1:-DerivedData/Build/Products/Release/Droidective.app}"
[[ -d "$APP" ]] || {
  echo "error: app not found: $APP — build the app first" >&2
  exit 1
}

HELPERS="$APP/Contents/Helpers"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"

command -v dylibbundler >/dev/null 2>&1 || {
  echo "error: dylibbundler missing — run 'brew install dylibbundler'" >&2
  exit 1
}

resolve() { # absolute path to a tool, or fail loudly
  command -v "$1" 2>/dev/null || {
    echo "error: '$1' not found on PATH — run 'brew install $1'" >&2
    exit 1
  }
}

SCRCPY="$(resolve scrcpy)"
FFMPEG="$(resolve ffmpeg)"

# scrcpy-server is a data blob scrcpy pushes to the device. Homebrew installs it
# at <prefix>/share/scrcpy/scrcpy-server; fall back to a Cellar glob.
prefix="$(cd "$(dirname "$SCRCPY")/.." && pwd)"
SERVER="$prefix/share/scrcpy/scrcpy-server"
if [[ ! -f "$SERVER" ]]; then
  SERVER="$(/bin/ls -1 "$prefix"/Cellar/scrcpy/*/share/scrcpy/scrcpy-server 2>/dev/null | head -1 || true)"
fi
[[ -f "$SERVER" ]] || {
  echo "error: scrcpy-server not found near $SCRCPY" >&2
  exit 1
}

mkdir -p "$HELPERS" "$FRAMEWORKS" "$RESOURCES"
cp -f "$SCRCPY" "$HELPERS/scrcpy"
cp -f "$FFMPEG" "$HELPERS/ffmpeg"
cp -f "$SERVER" "$RESOURCES/scrcpy-server"
chmod +x "$HELPERS/scrcpy" "$HELPERS/ffmpeg"

# dylibbundler copies each binary's full (transitive) dylib closure into
# Frameworks and rewrites the load commands to @executable_path-relative paths.
# Shared dependencies between scrcpy and ffmpeg are copied once.
dylibbundler -of -cd -b \
  -d "$FRAMEWORKS" \
  -p "@executable_path/../Frameworks/" \
  -x "$HELPERS/scrcpy" \
  -x "$HELPERS/ffmpeg"

echo "bundled scrcpy + ffmpeg into $APP"
