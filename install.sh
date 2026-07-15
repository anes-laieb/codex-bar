#!/bin/sh
# install.sh — install codex-macos-status (macOS only). Idempotent; safe to re-run.
#
# What it does:
#   1. Copies the runtime scripts into $CODEX_HOME/codex-macos-status/.
#   2. Installs + loads a LaunchAgent that runs the watcher (writes $CODEX_HOME/state
#      and fires notifications on turn-complete).
#   3. Copies the menu-bar plugin into your SwiftBar/xbar plugin folder if found.
#   4. (Optional, --with-notify-hook) wires the OPTIONAL notify hook into
#      config.toml, preserving any existing notify by chaining. Backs up first.
#
# Usage:  ./install.sh [--with-notify-hook]
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_DIR="$CODEX_HOME/codex-macos-status"
LA_DIR="$HOME/Library/LaunchAgents"
LABEL="com.codex-macos-status.watcher"
PLIST="$LA_DIR/$LABEL.plist"
MANIFEST="$INSTALL_DIR/uninstall-manifest.env"
GUI="gui/$(id -u)"

WITH_HOOK=0
for a in "$@"; do
  case "$a" in
    --with-notify-hook) WITH_HOOK=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# macOS only.
[ "$(uname -s)" = "Darwin" ] || { echo "error: macOS only." >&2; exit 1; }

PY=$(command -v python3 || true)
[ -n "$PY" ] || { echo "error: python3 not found. Run: xcode-select --install" >&2; exit 1; }

echo "==> installing runtime -> $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
for rel in bin/codex-watch bin/codex-notifier bin/codex-notify-hook bin/codex-status-sound tools/codex-notify-logger; do
  cp "$REPO_DIR/$rel" "$INSTALL_DIR/$(basename "$rel")"
  chmod +x "$INSTALL_DIR/$(basename "$rel")"
done

# Seed the state file so the menu bar shows something immediately.
"$PY" "$INSTALL_DIR/codex-watch" --print-state > "$CODEX_HOME/state" 2>/dev/null \
  || printf 'idle\n' > "$CODEX_HOME/state"

echo "==> installing LaunchAgent -> $PLIST"
mkdir -p "$LA_DIR"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$INSTALL_DIR/codex-watch</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>CODEX_HOME</key><string>$CODEX_HOME</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$INSTALL_DIR/watcher.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/watcher.log</string>
</dict>
</plist>
PLIST

# (Re)load robustly. A bootout immediately followed by bootstrap can hit a
# transient "Input/output error" that leaves the agent UNLOADED, so we retry
# bootstrap, fall back to legacy load, then verify and warn if it didn't stick.
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null \
  || launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null \
  || launchctl load -w "$PLIST" 2>/dev/null || true
launchctl enable "$GUI/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$GUI/$LABEL" 2>/dev/null || true
if launchctl print "$GUI/$LABEL" >/dev/null 2>&1; then
  echo "    watcher loaded ($LABEL)"
else
  echo "    WARNING: watcher failed to load. Retry: launchctl bootstrap $GUI \"$PLIST\""
fi

# Menu-bar plugin. SwiftBar's real preference domain is com.ameba.SwiftBar.
# SwiftBar runs EVERY file in its plugin folder (recursively) and chmods them
# executable, so the folder MUST be dedicated. We prefer an already-configured
# folder; if SwiftBar is installed but unconfigured we set up ~/.swiftbar.
PLUGIN_INSTALLED=""
SB=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
XB=$(defaults read com.xbarapp.app PluginDirectory 2>/dev/null || true)
DEST=""; APP=""
if [ -n "$SB" ] && [ -d "$SB" ]; then
  DEST="$SB"; APP="SwiftBar"
elif [ -n "$XB" ] && [ -d "$XB" ]; then
  DEST="$XB"; APP="xbar"
elif [ -d "/Applications/SwiftBar.app" ]; then
  DEST="$HOME/.swiftbar"; mkdir -p "$DEST"
  defaults write com.ameba.SwiftBar PluginDirectory "$DEST" 2>/dev/null || true
  APP="SwiftBar (created dedicated folder $DEST)"
fi

if [ -n "$DEST" ]; then
  cp "$REPO_DIR/plugins/codex-status.1s.sh" "$DEST/codex-status.1s.sh"
  chmod +x "$DEST/codex-status.1s.sh"
  PLUGIN_INSTALLED="$DEST/codex-status.1s.sh"
  echo "==> installed menu-bar plugin -> $PLUGIN_INSTALLED   [$APP]"
  subdirs=$(find "$DEST" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  others=$(find "$DEST" -mindepth 1 -maxdepth 1 ! -name 'codex-status.1s.sh' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${subdirs:-0}" -gt 0 ] || [ "${others:-0}" -gt 12 ]; then
    echo "    WARNING: $DEST is NOT a dedicated plugin folder (has subfolders/many files)."
    echo "             SwiftBar runs EVERY file in it and marks them executable."
    echo "             Point SwiftBar at a dedicated folder (e.g. ~/.swiftbar) to be safe."
  fi
else
  echo "==> SwiftBar/xbar not detected. For the menu-bar indicator:"
  echo "      brew install --cask swiftbar"
  echo "      open SwiftBar and set its plugin folder to a DEDICATED dir (e.g. ~/.swiftbar),"
  echo "      then re-run ./install.sh"
fi

# Optional notify hook (preserves any existing notify by chaining).
CONFIG_BACKUP=""
if [ "$WITH_HOOK" = 1 ]; then
  echo "==> wiring optional notify hook (chained, config.toml backed up)"
  OUT=$("$PY" "$REPO_DIR/tools/codex-config.py" chain-notify "$INSTALL_DIR/codex-notify-hook" 2>&1) || {
    echo "$OUT" >&2; echo "    notify hook NOT wired (see message above)."; }
  echo "$OUT" | sed 's/^/    /'
  CONFIG_BACKUP=$(printf '%s\n' "$OUT" | sed -n 's/^BACKUP=//p' | tail -1)
fi

# Carry a prior config backup forward if this run made no change (e.g. re-run
# with the hook already chained), so uninstall never loses the restore pointer.
if [ -z "$CONFIG_BACKUP" ] && [ -f "$MANIFEST" ]; then
  CONFIG_BACKUP=$(sed -n 's/^CONFIG_BACKUP=//p' "$MANIFEST" | tail -1)
fi

# Record what to undo.
{
  echo "INSTALL_DIR=$INSTALL_DIR"
  echo "PLIST=$PLIST"
  echo "LABEL=$LABEL"
  echo "PLUGIN_INSTALLED=$PLUGIN_INSTALLED"
  echo "CONFIG_BACKUP=$CONFIG_BACKUP"
} > "$MANIFEST"

echo ""
echo "Done."
echo "  • Turn-complete notifications: active now (via the watcher)."
echo "  • Menu bar: ${PLUGIN_INSTALLED:-install SwiftBar, then re-run ./install.sh}"
echo "  • Logs: $INSTALL_DIR/watcher.log    State: $CODEX_HOME/state"
echo "  • Uninstall: ./uninstall.sh"
