#!/usr/bin/env bash
# Regenerate docs/demo.gif from site/assets/demo.mp4 — the README's inline demo.
# GitHub can't play an externally-hosted <video> inline (its CSP blocks it), so
# the README embeds this GIF instead. Re-run after updating the demo video.
# Needs ffmpeg (Homebrew, or set FFMPEG=App/Resources/ffmpeg to use the bundled one).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$root/site/assets/demo.mp4"
out="$root/docs/demo.gif"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
palette="$work/palette.png"

ffmpeg="${FFMPEG:-ffmpeg}"
# 720px wide, 12 fps keeps a 30+ second UI demo a few MB rather than hundreds.
# A two-pass palette (diff stats + Bayer dither) holds quality at 256 colours.
filters="fps=12,scale=720:-1:flags=lanczos"

"$ffmpeg" -y -i "$src" -vf "${filters},palettegen=stats_mode=diff" "$palette"
"$ffmpeg" -y -i "$src" -i "$palette" \
  -lavfi "${filters}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$out"

echo "Wrote $out ($(du -h "$out" | cut -f1))"
