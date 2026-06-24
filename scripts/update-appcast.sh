#!/usr/bin/env bash
# Sign a built DMG with Sparkle's EdDSA key and (re)write the appcast feed.
# Produces a single-item appcast pointing at the GitHub release asset — all
# Sparkle needs to offer the latest version to every older install.
#
# Usage:
#   update-appcast.sh <dmg> <short-version> <build-version> <tag> <download-url> [appcast-out]
#
# The signing key is read from $SPARKLE_ED_PRIVATE_KEY (CI) or, when unset, from
# the login Keychain (local runs).
set -euo pipefail

DMG="${1:?dmg path required}"
SHORT_VERSION="${2:?marketing version required}"
BUILD_VERSION="${3:?build version required}"
TAG="${4:?tag required}"
DOWNLOAD_URL="${5:?download url required}"
APPCAST="${6:-site/appcast.xml}"

SIGN_UPDATE=".sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || {
  echo "error: $SIGN_UPDATE missing — run scripts/fetch-sparkle-tools.sh first" >&2
  exit 1
}
[[ -f "$DMG" ]] || {
  echo "error: DMG not found: $DMG" >&2
  exit 1
}

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  enclosure_attrs="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
  enclosure_attrs="$("$SIGN_UPDATE" "$DMG")"
fi

pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
mkdir -p "$(dirname "$APPCAST")"

cat >"$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Droidective</title>
    <link>https://droidective.github.io/Droidective/appcast.xml</link>
    <description>Most recent Droidective updates.</description>
    <language>en</language>
    <item>
      <title>Droidective ${SHORT_VERSION}</title>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/Droidective/Droidective/releases/tag/${TAG}</sparkle:releaseNotesLink>
      <pubDate>${pub_date}</pubDate>
      <enclosure url="${DOWNLOAD_URL}" ${enclosure_attrs} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "wrote $APPCAST ($SHORT_VERSION / build $BUILD_VERSION)"
