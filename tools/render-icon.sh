#!/bin/sh
# render-icon.sh — rasterize an SVG into per-state colored menu-bar icons.
#
# Produces icon-{idle,working,working2,approval,stale}.png in the install dir,
# each filled with the matching state color, so the menu-bar icon recolors by
# state (no separate dot needed). Uses macOS's built-in qlmanage — no deps.
#
# The SVG is NOT committed to this repo; run this on your own icon:
#   tools/render-icon.sh path/to/icon.svg
#
# Usage: render-icon.sh SOURCE.svg [DEST_DIR] [SIZE]
set -eu

SRC="$1"
DEST="${2:-${CODEX_HOME:-$HOME/.codex}/codex-macos-status}"
SIZE="${3:-36}"

[ -f "$SRC" ] || { echo "render-icon: no such file: $SRC" >&2; exit 1; }
command -v qlmanage >/dev/null 2>&1 || { echo "render-icon: qlmanage unavailable" >&2; exit 1; }
mkdir -p "$DEST"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() {  # name colorhex
  name="$1"; col="$2"
  # Force an explicit canvas (icons often declare width/height="1em") and set
  # the fill to the state color (the source uses fill="currentColor").
  sed -e 's/width="1em"/width="240"/' \
      -e 's/height="1em"/height="240"/' \
      -e "s/fill=\"currentColor\"/fill=\"$col\"/" "$SRC" > "$tmp/$name.svg"
  qlmanage -t -s "$SIZE" -o "$tmp" "$tmp/$name.svg" >/dev/null 2>&1 || true
  [ -f "$tmp/$name.svg.png" ] && cp "$tmp/$name.svg.png" "$DEST/icon-$name.png"
}

render idle     "#30d158"
render working  "#ffd60a"
render working2 "#a87f00"
render approval "#ff453a"
render stale    "#8e8e93"

echo "render-icon: wrote $(ls "$DEST"/icon-*.png 2>/dev/null | wc -l | tr -d ' ') icons to $DEST"