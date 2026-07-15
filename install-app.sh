#!/bin/sh
# install-app.sh — build & install the standalone Codex Status menu-bar app.
# This is the self-contained path: no SwiftBar, no Python watcher. It replaces
# them (and stops them, to avoid duplicate icons/notifications).
#
# Usage: ./install-app.sh
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
GUI="gui/$(id -u)"
WATCHER_LABEL="com.codex-macos-status.watcher"

[ "$(uname -s)" = "Darwin" ] || { echo "error: macOS only." >&2; exit 1; }

echo "==> building the app"
sh "$DIR/app/build.sh" "$DIR/app/build"
SRC="$DIR/app/build/CodexStatus.app"

echo "==> stopping the SwiftBar/Python path (avoids duplicates)"
launchctl bootout "$GUI/$WATCHER_LABEL" 2>/dev/null || true
# remove our SwiftBar plugin if present, in current + configured plugin dirs
rm -f "$HOME/.swiftbar/codex-status.1s.sh" 2>/dev/null || true
for app in com.ameba.SwiftBar com.xbarapp.app; do
  d=$(defaults read "$app" PluginDirectory 2>/dev/null || true)
  [ -n "$d" ] && rm -f "$d/codex-status.1s.sh" 2>/dev/null || true
done

echo "==> installing the app"
DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/CodexStatus.app"
cp -R "$SRC" "$DEST_DIR/"
DEST="$DEST_DIR/CodexStatus.app"

echo "==> launching"
open "$DEST"

echo ""
echo "Done. 'Codex Status' is running in your menu bar (look for the </> icon)."
echo "  • App: $DEST"
echo "  • Enable 'Launch at Login' from its menu to keep it across restarts."
echo "  • Quit from its menu; delete $DEST to uninstall."
