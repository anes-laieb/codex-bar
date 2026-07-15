#!/bin/sh
# codex-status.1s.sh — SwiftBar / xbar plugin for codex-macos-status.
#
# Renders a menu-bar indicator from $CODEX_HOME/state, refreshing ~1s (see the
# ".1s" in the filename). Works with both SwiftBar and xbar: only the shared
# output format (title line, "---", then menu items with "| key=value" params)
# is used.
#
#  <xbar.title>Codex Status</xbar.title>
#  <xbar.version>1.0.0</xbar.version>
#  <xbar.author>codex-macos-status</xbar.author>
#  <xbar.desc>Menu-bar indicator for the Codex CLI: idle / working / needs approval.</xbar.desc>
#  <xbar.dependencies>codex-macos-status</xbar.dependencies>
#  <swiftbar.hideAbout>true</swiftbar.hideAbout>
#  <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#  <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#  <swiftbar.hideDisableClicks>true</swiftbar.hideDisableClicks>

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
STATE_FILE="$CODEX_DIR/state"
STALE_SECS=30          # watcher heartbeats every ~10s; older than this = not running

state="unknown"
age="n/a"
if [ -f "$STATE_FILE" ]; then
  state=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)
  now=$(date +%s)
  mt=$(stat -f %m "$STATE_FILE" 2>/dev/null || echo "$now")
  age=$(( now - mt ))
  [ "$age" -gt "$STALE_SECS" ] && state="stale"
fi

case "$state" in
  idle)           icon="🟢"; label="Codex: idle";;
  working)        icon="🟡"; label="Codex: working";;
  needs-approval) icon="🔴"; label="Codex: needs approval";;
  stale)          icon="⚪"; label="Codex: watcher not running";;
  *)              icon="⚪"; label="Codex: status unknown";;
esac

# Menu-bar title (first line before the separator).
echo "$icon"
echo "---"
echo "$label | color=#8e8e93"
if [ "$state" = "stale" ]; then
  echo "State file not updating (${age}s old) | color=#ff9500"
  echo "Start the watcher: install.sh | color=#8e8e93"
fi
echo "State file: $STATE_FILE | color=#8e8e93 font=Menlo size=11"
echo "---"
echo "Refresh | refresh=true"
