#!/usr/bin/env bash
# Download Sparkle's command-line tools (generate_keys, sign_update) into
# .sparkle/bin — used locally to create signing keys and in CI to sign updates.
set -euo pipefail

SPARKLE_VERSION="2.9.3"
DEST=".sparkle"
BIN="$DEST/bin"

if [[ -x "$BIN/sign_update" && -x "$BIN/generate_keys" ]]; then
  echo "Sparkle tools already present in $BIN"
  exit 0
fi

url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Sparkle ${SPARKLE_VERSION} tools…"
curl -fsSL "$url" -o "$tmp/sparkle.tar.xz"
tar -xJf "$tmp/sparkle.tar.xz" -C "$tmp"

mkdir -p "$BIN"
cp -R "$tmp"/bin/. "$BIN"/
echo "Sparkle tools ready in $BIN"
