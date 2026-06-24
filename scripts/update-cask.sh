#!/usr/bin/env bash
# Render the Homebrew cask for a release. The release job runs this against a
# checkout of the tap repo, then commits the result.
#
# Usage: update-cask.sh <version> <dmg> <download-url> <cask-file>
set -euo pipefail

VERSION="${1:?version required}"
DMG="${2:?dmg path required}"
URL="${3:?download url required}"
OUT="${4:?output cask path required}"

[[ -f "$DMG" ]] || {
  echo "error: DMG not found: $DMG" >&2
  exit 1
}

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
mkdir -p "$(dirname "$OUT")"

cat >"$OUT" <<RUBY
cask "droidective" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "${URL}"
  name "Droidective"
  desc "Native macOS app for Android and React Native debugging over adb"
  homepage "https://droidective.github.io/Droidective/"

  # Sparkle updates the app in place, so Homebrew should not fight it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Droidective.app"

  zap trash: [
    "~/Library/Application Support/Droidective",
    "~/Library/Preferences/com.rohindh.droidective.plist",
  ]
end
RUBY

echo "wrote $OUT (v${VERSION}, sha256 ${SHA})"
