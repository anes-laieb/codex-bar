#!/bin/bash
# codex-status.1s.sh — SwiftBar / xbar menu-bar indicator for codex-macos-status.
#
# One small SF-Symbol icon, colored by state (green idle · amber working ·
# red needs-approval · gray watcher-down). While a turn runs it shows a cycling
# word (Thinking… / Cooking… / Prompting…) with a small blooming-flower spinner,
# Claude-Code style. Click for live details and a sound toggle.
#
# Under SwiftBar it streams (smooth animation, lean text-only output so the menu
# stays clickable). Under xbar it prints one static frame.
#
#  <xbar.title>Codex Status</xbar.title>
#  <xbar.version>1.3.0</xbar.version>
#  <xbar.author>codex-macos-status</xbar.author>
#  <xbar.desc>Menu-bar indicator for the Codex CLI: idle / working / needs approval.</xbar.desc>
#  <swiftbar.type>streamable</swiftbar.type>
#  <swiftbar.hideAbout>true</swiftbar.hideAbout>
#  <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#  <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#  <swiftbar.hideDisableClicks>true</swiftbar.hideDisableClicks>

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
STATUS="$CODEX_DIR/status"
STATE_FILE="$CODEX_DIR/state"
INST="$CODEX_DIR/codex-macos-status"
LOGF="$INST/watcher.log"
SESS="$CODEX_DIR/sessions"
SNDFILE="$INST/sound"
SNDHELP="$INST/codex-status-sound"
STALE=30

# Change ICON to any SF Symbol name (SF Symbols app), e.g. "sparkle",
# "terminal.fill", "hexagon.fill".
ICON="chevron.left.forwardslash.chevron.right"
FLOWER=( "✿" "❀" "✾" "❁" "❋" "✾" "❀" )
WORDS=( "Thinking" "Cooking" "Prompting" "Brewing" "Reasoning" "Crunching" \
        "Pondering" "Plotting" "Noodling" "Simmering" "Vibing" "Scheming" )

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

render() {
  local i=$1 now ago eff color sf title label word fl snd chk
  now=$(date +%s)
  load
  ago=""; [ -n "$updated_at" ] && ago=$(( now - updated_at ))
  eff="$state"
  if [ -n "$ago" ] && [ "$ago" -gt "$STALE" ] && [ "$state" != "unknown" ]; then eff="stale"; fi

  sf="$ICON"
  case "$eff" in
    working)
      color="#ffd60a"; label="working"
      word="${WORDS[$(( (i / 8) % ${#WORDS[@]} ))]}"
      fl="${FLOWER[$(( i % ${#FLOWER[@]} ))]}"
      title="${word} ${fl}" ;;
    idle)           color="#30d158"; title=""; label="idle" ;;
    needs-approval) color="#ff453a"; title="Approval"; label="needs approval" ;;
    stale)          color="#8e8e93"; title=""; label="watcher not running" ;;
    *)              color="#8e8e93"; title=""; label="unknown" ;;
  esac

  # menu bar: icon (+ cycling word while working); no heavy image → stays clickable
  if [ -n "$title" ]; then echo "${title} | sfimage=${sf} sfcolor=${color}"
  else echo "| sfimage=${sf} sfcolor=${color}"; fi

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
    local m="${last_message//|/¦}"
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
  # sound: a checkable toggle (checkmark = on). Streaming reflects the flip.
  snd=on; [ -f "$SNDFILE" ] && snd=$(tr -d '[:space:]' < "$SNDFILE"); [ "$snd" = "off" ] || snd=on
  chk=false; [ "$snd" = "on" ] && chk=true
  echo "Completion sound | checked=${chk} bash=\"$SNDHELP\" param1=toggle terminal=false"
  echo "---"
  if [ "$eff" = "stale" ]; then
    echo "Watcher not updating (${ago}s) — run ./install.sh | color=#ff9f0a"
  elif [ -n "$ago" ]; then
    echo "Updated ${ago}s ago | size=11 color=#8e8e93"
  fi
  echo "Open watcher log | bash=/usr/bin/open param1=\"$LOGF\" terminal=false"
  echo "Open sessions folder | bash=/usr/bin/open param1=\"$SESS\" terminal=false"
  echo "Refresh | refresh=true"
}

# xbar / manual: one static frame.
if [ -z "${SWIFTBAR:-}${SWIFTBAR_RUNNING_VERSION:-}" ]; then
  render 0
  exit 0
fi

# SwiftBar streamable: animate. Fast frames only while working.
i=0
while true; do
  render "$i"
  echo "~~~"
  st=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)
  if [ "$st" = "working" ]; then sleep 0.25; else sleep 1; fi
  i=$(( i + 1 ))
done
