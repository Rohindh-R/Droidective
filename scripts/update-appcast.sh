#!/usr/bin/env bash
# Sign a built DMG with Sparkle's EdDSA key and (re)write the appcast feed.
# Produces a single-item appcast whose enclosure points at the GitHub release
# asset and whose <description> carries the release notes inline as HTML — so
# Sparkle renders the notes in its update window instead of loading the GitHub
# release web page (which dragged in the whole site chrome).
#
# Usage:
#   update-appcast.sh <dmg> <short-version> <build-version> <download-url> <notes-md> [appcast-out]
#
# <notes-md> is this release's section in Markdown (the same file used for the
# GitHub release body). It's rendered to HTML with GitHub's /markdown API — so
# it matches the release page — and embedded in <description>.
#
# The signing key is read from $SPARKLE_ED_PRIVATE_KEY (CI) or, when unset, from
# the login Keychain (local runs). gh must be authenticated (GH_TOKEN in CI).
set -euo pipefail

DMG="${1:?dmg path required}"
SHORT_VERSION="${2:?marketing version required}"
BUILD_VERSION="${3:?build version required}"
DOWNLOAD_URL="${4:?download url required}"
NOTES_MD="${5:?release notes markdown path required}"
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
[[ -f "$NOTES_MD" ]] || {
  echo "error: release notes not found: $NOTES_MD" >&2
  exit 1
}
command -v gh >/dev/null || {
  echo "error: gh (GitHub CLI) required to render release notes" >&2
  exit 1
}

# Sparkle's notes are this version's section minus the redundant version heading
# (Sparkle's UI already shows the version) and the "Install" subsection (its
# "download the .dmg below" steps make no sense in an updater that installs for
# you). Both filters are no-ops when those lines are absent.
notes_md="$(awk 'NR==1 && /^## /{next} /^### Install/{exit} {print}' "$NOTES_MD")"

# Render Markdown -> HTML with GitHub's renderer (so it matches the release
# page), then strip GitHub's heading chrome — the permalink octicon anchors and
# wrapper divs render as broken glyphs in Sparkle's plain web view.
notes_html="$(gh api --method POST /markdown -f text="$notes_md" -f mode=markdown |
  sed -E 's#<a id="user-content-[^"]*" class="anchor"[^>]*>.*</a>##g; s#<div class="markdown-heading">##g; s#</div>##g; s# class="heading-element"##g')"

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
    <link>https://droidective.com/appcast.xml</link>
    <description>Most recent Droidective updates.</description>
    <language>en</language>
    <item>
      <title>Droidective ${SHORT_VERSION}</title>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
<style>
:root { color-scheme: light dark; }
body { font: 13px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; }
h2 { font-size: 1.3em; margin: .2em 0 .4em; }
h3 { font-size: 1.05em; margin: 1.1em 0 .3em; }
p { margin: .5em 0; }
ul { margin: .4em 0; padding-left: 1.4em; }
li { margin: .3em 0; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; background: color-mix(in srgb, currentColor 12%, transparent); padding: .1em .35em; border-radius: 4px; }
pre { background: color-mix(in srgb, currentColor 8%, transparent); padding: .6em .8em; border-radius: 6px; overflow-x: auto; }
pre code { background: none; padding: 0; }
a { color: #2f9e44; }
</style>
${notes_html}
]]></description>
      <pubDate>${pub_date}</pubDate>
      <enclosure url="${DOWNLOAD_URL}" ${enclosure_attrs} type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

# The <description> now carries generated HTML, so confirm the feed still parses
# before it's committed — a malformed appcast silently stops every client's
# updates. (Skipped, with a warning, only if xmllint isn't installed.)
if command -v xmllint >/dev/null; then
  xmllint --noout "$APPCAST" || {
    echo "error: generated $APPCAST is not well-formed XML" >&2
    exit 1
  }
else
  echo "warning: xmllint not found — skipping appcast validation" >&2
fi

echo "wrote $APPCAST ($SHORT_VERSION / build $BUILD_VERSION)"
