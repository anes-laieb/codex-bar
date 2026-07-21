#!/bin/sh
# build.sh — compile the Codex Bar menu-bar app into "Codex Bar.app". macOS only.
# Usage: build.sh [OUTPUT_DIR]   (default: ./build next to this script)
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$DIR/build}"
APP="$OUT/Codex Bar.app"

command -v swiftc >/dev/null 2>&1 || xcrun --find swiftc >/dev/null 2>&1 \
  || { echo "error: swiftc not found. Install Xcode command line tools: xcode-select --install" >&2; exit 1; }
SWIFTC=$(command -v swiftc 2>/dev/null || xcrun --find swiftc)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
"$SWIFTC" -swift-version 5 -O "$DIR/CodexStatus.swift" -o "$APP/Contents/MacOS/CodexBar"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp -R "$DIR/StatusAssets" "$APP/Contents/Resources/"
cp "$DIR/../LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$DIR/../NOTICE" "$APP/Contents/Resources/NOTICE"

# App icon: build an iconset from the supplied app-logo artwork.
if command -v qlmanage >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  base="$DIR/StatusAssets/app-logo.png"
  if [ ! -f "$base" ]; then
    qlmanage -t -s 1024 -o "$tmp" "$DIR/AppIcon.svg" >/dev/null 2>&1 || true
    base="$tmp/AppIcon.svg.png"
  fi
  if [ -f "$base" ]; then
    # Keep the artwork comfortably inside the macOS icon canvas. The source is
    # intentionally borderless, so normalize it onto a transparent 1024 px
    # canvas before producing the iconset rather than letting it touch the edge.
    normalized="$tmp/app-logo-normalized.png"
    artwork="$tmp/app-logo-artwork.png"
    sips -Z 880 "$base" --out "$artwork" >/dev/null 2>&1 || true
    sips -p 1024 1024 "$artwork" --out "$normalized" >/dev/null 2>&1 || true
    if [ -f "$normalized" ]; then
      base="$normalized"
    fi
    iset="$tmp/AppIcon.iconset"; mkdir -p "$iset"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$base" --out "$iset/icon_${s}x${s}.png" >/dev/null 2>&1 || true
      d=$(( s * 2 ))
      sips -z "$d" "$d" "$base" --out "$iset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$iset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  fi
  rm -rf "$tmp"
fi

# Ad-hoc sign so a locally-built app launches cleanly.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
