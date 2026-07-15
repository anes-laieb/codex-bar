#!/bin/sh
# extract-logo.sh — copy the Codex logo out of the locally-installed Codex /
# ChatGPT app for use as the menu-bar icon. Best-effort, macOS only.
#
# The Codex logo is a trademark of its owner. It is NOT distributed with this
# repository; this script only reads an asset already present on the user's
# machine and writes resized copies into the install dir (which is git-ignored).
# If the app isn't installed, the plugin falls back to a "</>" SF Symbol.
#
# Usage: extract-logo.sh [DEST_DIR]   (default: $CODEX_HOME/codex-macos-status)
set -eu

DEST="${1:-${CODEX_HOME:-$HOME/.codex}/codex-macos-status}"
APP="/Applications/ChatGPT.app/Contents/Resources"
SIZE=36   # menu-bar icons render ~18pt; 36px is crisp on retina
mkdir -p "$DEST"

command -v sips >/dev/null 2>&1 || { echo "sips not available; skipping logo."; exit 0; }

made=0
# white-tile variant reads well on DARK menu bars; black-tile on LIGHT menu bars.
if [ -f "$APP/icon-codex-light.png" ]; then
  sips -Z "$SIZE" "$APP/icon-codex-light.png" --out "$DEST/logo-for-dark.png" >/dev/null 2>&1 && made=1
fi
if [ -f "$APP/icon-codex-dark-color.png" ]; then
  sips -Z "$SIZE" "$APP/icon-codex-dark-color.png" --out "$DEST/logo-for-light.png" >/dev/null 2>&1 && made=1
fi

if [ "$made" = 1 ]; then
  echo "extracted Codex logo -> $DEST/logo-for-{dark,light}.png"
else
  echo "Codex app logo not found; the plugin will use the </> glyph."
fi