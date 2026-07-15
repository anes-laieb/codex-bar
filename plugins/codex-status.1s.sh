#!/bin/bash
# codex-status.1s.sh — SwiftBar / xbar menu-bar indicator for codex-macos-status.
#
# Shows ONE small icon, colored by state:
#   green = idle · amber = working (gentle pulse) · red = needs approval · gray = watcher down
# Click it for live details: elapsed, project, model · effort, approvals, last message.
#
# Deliberately NOT streaming and text-free in the menu bar, so the item never
# overflows and the dropdown is always clickable. Refreshes ~1s (filename).
#
#  <xbar.title>Codex Status</xbar.title>
#  <xbar.version>1.2.0</xbar.version>
#  <xbar.author>codex-macos-status</xbar.author>
#  <xbar.desc>Menu-bar indicator for the Codex CLI: idle / working / needs approval.</xbar.desc>
#  <swiftbar.hideAbout>true</swiftbar.hideAbout>
#  <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#  <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#  <swiftbar.hideDisableClicks>true</swiftbar.hideDisableClicks>

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
STATUS="$CODEX_DIR/status"
STATE_FILE="$CODEX_DIR/state"
LOGF="$CODEX_DIR/codex-macos-status/watcher.log"
SESS="$CODEX_DIR/sessions"
STALE=30

# The icon is an SF Symbol — change ICON to any name from the SF Symbols app
# (e.g. "chevron.left.forwardslash.chevron.right", "terminal.fill", "hexagon.fill").
ICON="sparkle"                         # SF Symbol fallback if no rendered icons
WORK_FRAMES=( "sparkle" "sparkles" )
# Per-state colored PNGs rendered from an SVG by tools/render-icon.sh, if present
# (icon-idle / icon-working / icon-working2 / icon-approval / icon-stale).
ICON_DIR="$CODEX_DIR/codex-macos-status"

fmt_dur() {
  s=$1; [ -z "$s" ] && { echo ""; return; }
  m=$(( s / 60 )); r=$(( s % 60 ))
  if [ "$m" -gt 0 ]; then echo "${m}m ${r}s"; else echo "${r}s"; fi
}

load() {
  state=""; model=""; effort=""; approval_policy=""; cwd=""; originator=""
  cli_version=""; started_at=""; duration_ms=""; last_message=""; updated_at=""
  if [ -f "$STATUS" ]; then
    while IFS=$'\t' read -r k v; do
      case "$k" in
        state) state=$v ;; model) model=$v ;; effort) effort=$v ;;
        approval_policy) approval_policy=$v ;; cwd) cwd=$v ;;
        originator) originator=$v ;; cli_version) cli_version=$v ;;
        started_at) started_at=$v ;; duration_ms) duration_ms=$v ;;
        last_message) last_message=$v ;; updated_at) updated_at=$v ;;
      esac
    done < "$STATUS"
  elif [ -f "$STATE_FILE" ]; then
    state=$(tr -d '[:space:]' < "$STATE_FILE")
    updated_at=$(stat -f %m "$STATE_FILE" 2>/dev/null)
  fi
  [ -z "$state" ] && state="unknown"
}

now=$(date +%s)
load
ago=""; [ -n "$updated_at" ] && ago=$(( now - updated_at ))
eff="$state"
if [ -n "$ago" ] && [ "$ago" -gt "$STALE" ] && [ "$state" != "unknown" ]; then eff="stale"; fi

case "$eff" in
  working)        color="#ffd60a"; sf="${WORK_FRAMES[$(( now % ${#WORK_FRAMES[@]} ))]}"; label="working" ;;
  idle)           color="#30d158"; sf="$ICON"; label="idle" ;;
  needs-approval) color="#ff453a"; sf="exclamationmark.triangle.fill"; label="needs approval" ;;
  stale)          color="#8e8e93"; sf="$ICON"; label="watcher not running" ;;
  *)              color="#8e8e93"; sf="$ICON"; label="unknown" ;;
esac

# Menu bar: the rendered per-state icon if available (recolors by state, with a
# gentle 2-frame working pulse), else a colored SF Symbol.
case "$eff" in
  working) if [ $(( now % 2 )) -eq 0 ]; then ifile="$ICON_DIR/icon-working.png"; else ifile="$ICON_DIR/icon-working2.png"; fi ;;
  idle)           ifile="$ICON_DIR/icon-idle.png" ;;
  needs-approval) ifile="$ICON_DIR/icon-approval.png" ;;
  *)              ifile="$ICON_DIR/icon-stale.png" ;;
esac
if [ -f "$ifile" ]; then
  echo "| image=$(base64 < "$ifile" | tr -d '\n')"
else
  echo "| sfimage=${sf} sfcolor=${color}"
fi

echo "---"
echo "Codex — ${label} | sfimage=${sf} sfcolor=${color}"
if [ "$eff" = "working" ] && [ -n "$started_at" ]; then
  echo "Running for $(fmt_dur $(( now - started_at ))) | color=#8e8e93"
elif [ -n "$duration_ms" ]; then
  echo "Last turn: $(fmt_dur $(( duration_ms / 1000 ))) | color=#8e8e93"
fi
[ -n "$cwd" ] && echo "Project: $(basename "$cwd") | color=#8e8e93"
if [ -n "$model" ]; then
  if [ -n "$effort" ]; then echo "Model: ${model}  ·  ${effort} | color=#8e8e93"
  else echo "Model: ${model} | color=#8e8e93"; fi
fi
[ -n "$approval_policy" ] && echo "Approvals: ${approval_policy} | color=#8e8e93"

if [ -n "$last_message" ]; then
  m="${last_message//|/¦}"
  echo "---"
  if [ "${#m}" -gt 64 ]; then
    echo "${m:0:64}… | color=#c7c9cf"
    echo "Full message | color=#8e8e93"
    echo "--${m:0:480}"
  else
    echo "${m} | color=#c7c9cf"
  fi
fi

echo "---"
if [ "$eff" = "stale" ]; then
  echo "Watcher not updating (${ago}s) — run ./install.sh | color=#ff9f0a"
elif [ -n "$ago" ]; then
  echo "Updated ${ago}s ago | size=11 color=#8e8e93"
fi
snd=on; [ -f "$ICON_DIR/sound" ] && snd=$(tr -d '[:space:]' < "$ICON_DIR/sound")
[ "$snd" = "off" ] || snd=on
if [ "$snd" = "on" ]; then
  echo "🔔 Completion sound: on | bash=\"$ICON_DIR/codex-status-sound\" param1=toggle terminal=false refresh=true"
else
  echo "🔕 Completion sound: off | bash=\"$ICON_DIR/codex-status-sound\" param1=toggle terminal=false refresh=true"
fi
echo "Open watcher log | bash=/usr/bin/open param1=\"$LOGF\" terminal=false"
echo "Open sessions folder | bash=/usr/bin/open param1=\"$SESS\" terminal=false"
echo "Refresh | refresh=true"
