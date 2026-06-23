#!/usr/bin/env bash
# Refresh the third-party binaries bundled in the app (App/Resources/), so the
# app stays self-contained (no `brew install scrcpy`/`ffmpeg`).
#
#   scripts/update-bundled-tools.sh [scrcpy_version]
#
# Downloads:
#   - scrcpy-server  from the scrcpy GitHub release (default v4.0)
#   - ffmpeg         latest static build, macOS arm64 (ffmpeg.martin-riedl.de)
#
# After running, bump the version constants in
# App/Sources/Bundled/BundledTools.swift if they changed (the scrcpy version
# MUST match the server payload), then `make build` and commit. The bundled
# ffmpeg is GPLv3 — see THIRD_PARTY_NOTICES.md.
set -euo pipefail

SCRCPY_VERSION="${1:-4.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/App/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> scrcpy-server v$SCRCPY_VERSION"
curl -fsSL -o "$RES/scrcpy-server" \
  "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"

echo "==> ffmpeg (latest static, macOS arm64)"
curl -fsSL -o "$TMP/ffmpeg.zip" \
  "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
unzip -o -q "$TMP/ffmpeg.zip" -d "$TMP"
mv "$TMP/ffmpeg" "$RES/ffmpeg"
chmod +x "$RES/ffmpeg"

ffmpeg_version="$("$RES/ffmpeg" -version | head -1 | cut -d' ' -f3)"

echo
echo "Bundled (sha256):"
printf '  scrcpy-server  %s\n' "$(shasum -a 256 "$RES/scrcpy-server" | cut -d' ' -f1)"
printf '  ffmpeg         %s\n' "$(shasum -a 256 "$RES/ffmpeg" | cut -d' ' -f1)"
echo
echo "Versions: scrcpy=$SCRCPY_VERSION  ffmpeg=$ffmpeg_version"
echo "Next: set BundledTools.scrcpyVersion=\"$SCRCPY_VERSION\" if it changed,"
echo "update the ffmpeg version in THIRD_PARTY_NOTICES.md, then 'make build' and commit."
