#!/bin/sh
# install-app.sh — build & install the standalone "Codex Bar" menu-bar app.
# Self-contained: no SwiftBar, no Python watcher. It replaces (and stops) them.
#
# Usage: ./install-app.sh
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
GUI="gui/$(id -u)"
WATCHER_LABEL="com.codex-macos-status.watcher"

[ "$(uname -s)" = "Darwin" ] || { echo "error: macOS only." >&2; exit 1; }

echo "==> building the app"
sh "$DIR/app/build.sh" "$DIR/app/build"
SRC="$DIR/app/build/Codex Bar.app"

echo "==> stopping the SwiftBar/Python path (avoids duplicates)"
launchctl bootout "$GUI/$WATCHER_LABEL" 2>/dev/null || true
rm -f "$HOME/.swiftbar/codex-status.1s.sh" 2>/dev/null || true
for a in com.ameba.SwiftBar com.xbarapp.app; do
  d=$(defaults read "$a" PluginDirectory 2>/dev/null || true)
  [ -n "$d" ] && rm -f "$d/codex-status.1s.sh" 2>/dev/null || true
done

echo "==> installing the app"
DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
# Remove any previous build (old name too) in both common locations.
killall CodexBar CodexStatus 2>/dev/null || true
for loc in "/Applications" "$HOME/Applications"; do
  rm -rf "$loc/CodexStatus.app" "$loc/Codex Bar.app" 2>/dev/null || true
done
cp -R "$SRC" "$DEST_DIR/"
DEST="$DEST_DIR/Codex Bar.app"
# Don't leave a second copy in the repo for Spotlight/Launchpad to index.
rm -rf "$DIR/app/build"

echo "==> launching"
open "$DEST"

echo ""
echo "Done. 'Codex Bar' is running in your menu bar (look for the sparkle icon)."
echo "  • App: $DEST"
echo "  • Enable 'Launch at Login' from its menu to keep it across restarts."
echo "  • Uninstall: quit it from its menu, then delete \"$DEST\"."
