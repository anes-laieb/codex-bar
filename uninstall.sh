#!/bin/sh
# uninstall.sh — remove codex-macos-status and revert changes. Idempotent.
#
# Reverses install.sh: unloads + removes the LaunchAgent, removes the menu-bar
# plugin, restores config.toml from the backup made when the notify hook was
# wired (if it was), and removes the runtime install dir. Leaves $CODEX_HOME
# otherwise untouched.
#
# Usage:  ./uninstall.sh [--purge]
#   --purge   also delete $CODEX_HOME/state and $CODEX_HOME/notify*.log
set -eu

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_DIR="$CODEX_HOME/codex-macos-status"
LA_DIR="$HOME/Library/LaunchAgents"
LABEL="com.codex-macos-status.watcher"
PLIST="$LA_DIR/$LABEL.plist"
MANIFEST="$INSTALL_DIR/uninstall-manifest.env"
GUI="gui/$(id -u)"
REPO_DIR=$(cd "$(dirname "$0")" && pwd)

PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# Load manifest values if present.
PLUGIN_INSTALLED=""; CONFIG_BACKUP=""
if [ -f "$MANIFEST" ]; then
  # shellcheck disable=SC1090
  . "$MANIFEST"
fi

echo "==> unloading LaunchAgent"
launchctl bootout "$GUI/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "    removed $PLIST" || true

echo "==> removing menu-bar plugin"
removed_plugin=0
if [ -n "${PLUGIN_INSTALLED:-}" ] && [ -f "$PLUGIN_INSTALLED" ]; then
  rm -f "$PLUGIN_INSTALLED" && echo "    removed $PLUGIN_INSTALLED"; removed_plugin=1
fi
# Belt-and-suspenders: also check current SwiftBar/xbar plugin dirs.
for pref in com.ambar.SwiftBar:PluginDirectory com.xbarapp.app:PluginDirectory; do
  app=${pref%%:*}; key=${pref##*:}
  dir=$(defaults read "$app" "$key" 2>/dev/null || true)
  if [ -n "$dir" ] && [ -f "$dir/codex-status.1s.sh" ]; then
    rm -f "$dir/codex-status.1s.sh" && echo "    removed $dir/codex-status.1s.sh"; removed_plugin=1
  fi
done
[ "$removed_plugin" = 0 ] && echo "    (no plugin file found)"

# Restore config.toml only if we wired the notify hook.
if [ -n "${CONFIG_BACKUP:-}" ] && [ -f "$CONFIG_BACKUP" ]; then
  echo "==> restoring config.toml from $CONFIG_BACKUP"
  python3 "$REPO_DIR/tools/codex-config.py" restore "$CONFIG_BACKUP" 2>/dev/null \
    || cp "$CONFIG_BACKUP" "$CODEX_HOME/config.toml"
else
  echo "==> config.toml untouched (notify hook was not wired by installer)"
fi

echo "==> removing runtime dir"
[ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR" && echo "    removed $INSTALL_DIR" || true

if [ "$PURGE" = 1 ]; then
  echo "==> purging state + logs"
  rm -f "$CODEX_HOME/state" "$CODEX_HOME/state.tmp" \
        "$CODEX_HOME/notify.log" "$CODEX_HOME/notify.debug.log" 2>/dev/null || true
fi

echo "Done. codex-macos-status removed."
