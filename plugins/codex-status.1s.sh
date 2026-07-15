#!/bin/bash
# codex-status.1s.sh — SwiftBar / xbar menu-bar indicator for codex-macos-status.
#
# Reads $CODEX_HOME/status (written by codex-watch) and renders:
#   • a Codex "</>" glyph, colored by state (green idle / amber working / red approval)
#   • a "Working" label with a live blooming-flower animation while a turn runs
#   • a dropdown with elapsed time, project, model·effort, approval policy, last message
#
# Under SwiftBar it runs as a *streamable* plugin (a loop) for smooth animation.
# Under xbar (or run by hand) it prints one static frame and exits.
#
#  <xbar.title>Codex Status</xbar.title>
#  <xbar.version>1.1.0</xbar.version>
#  <xbar.author>codex-macos-status</xbar.author>
#  <xbar.desc>Menu-bar indicator for the Codex CLI: idle / working / needs approval, with live turn info.</xbar.desc>
#  <swiftbar.type>streamable</swiftbar.type>
#  <swiftbar.hideAbout>true</swiftbar.hideAbout>
#  <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#  <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#  <swiftbar.hideDisableClicks>true</swiftbar.hideDisableClicks>

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
STATUS="$CODEX_DIR/status"
STATE_FILE="$CODEX_DIR/state"
LOGF="$CODEX_DIR/codex-macos-status/watcher.log"
SESS="$CODEX_DIR/sessions"
ICON="chevron.left.forwardslash.chevron.right"   # the "</>" Codex glyph
STALE=30                                          # watcher heartbeats ~10s
FLOWER=( "✿" "❀" "✾" "❁" "❋" "✾" "❀" )            # bloom animation frames

fmt_dur() {  # seconds -> "Xm Ys" / "Ys"
  s=$1; [ -z "$s" ] && { echo ""; return; }
  m=$(( s / 60 )); r=$(( s % 60 ))
  if [ "$m" -gt 0 ]; then echo "${m}m ${r}s"; else echo "${r}s"; fi
}

load() {  # parse the TAB-separated status file into shell vars (bash 3.2 safe)
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
  elif [ -f "$STATE_FILE" ]; then          # fall back to the one-word state file
    state=$(tr -d '[:space:]' < "$STATE_FILE")
    updated_at=$(stat -f %m "$STATE_FILE" 2>/dev/null)
  fi
  [ -z "$state" ] && state="unknown"
}

render() {
  local i=$1 now ago eff color sf title label params
  now=$(date +%s)
  load
  ago=""; [ -n "$updated_at" ] && ago=$(( now - updated_at ))
  eff="$state"
  if [ -n "$ago" ] && [ "$ago" -gt "$STALE" ] && [ "$state" != "unknown" ]; then eff="stale"; fi

  sf="$ICON"
  case "$eff" in
    working)        color="#ffd60a"; title="Working ${FLOWER[$(( i % ${#FLOWER[@]} ))]}"; label="working" ;;
    idle)           color="#30d158"; title="";         label="idle" ;;
    needs-approval) color="#ff453a"; sf="exclamationmark.triangle.fill"; title="Approval"; label="needs approval" ;;
    stale)          color="#8e8e93"; title="";         label="watcher not running" ;;
    *)              color="#8e8e93"; title="";         label="unknown" ;;
  esac

  # menu-bar title: icon (+ text when working/approval)
  params="sfimage=${sf} sfcolor=${color}"
  if [ -n "$title" ]; then echo "${title} | ${params}"; else echo "| ${params}"; fi

  echo "---"
  echo "Codex — ${label} | ${params}"
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
    local m="${last_message//|/¦}"          # '|' would break SwiftBar's parser
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
  echo "Open watcher log | bash=/usr/bin/open param1=\"$LOGF\" terminal=false"
  echo "Open sessions folder | bash=/usr/bin/open param1=\"$SESS\" terminal=false"
  echo "Refresh | refresh=true"
}

# xbar / manual invocation: one static frame.
if [ -z "${SWIFTBAR:-}${SWIFTBAR_RUNNING_VERSION:-}" ]; then
  render 0
  exit 0
fi

# SwiftBar streamable: loop and animate. Fast frames only while working.
i=0
while true; do
  render "$i"
  echo "~~~"
  st=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)
  if [ "$st" = "working" ]; then sleep 0.15; else sleep 1; fi
  i=$(( i + 1 ))
done
