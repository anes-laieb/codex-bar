#!/bin/sh
# build.sh — compile CodexStatus.swift into a CodexStatus.app bundle. macOS only.
# Usage: build.sh [OUTPUT_DIR]   (default: ./build next to this script)
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$DIR/build}"
APP="$OUT/CodexStatus.app"

command -v swiftc >/dev/null 2>&1 || xcrun --find swiftc >/dev/null 2>&1 \
  || { echo "error: swiftc not found. Install Xcode command line tools: xcode-select --install" >&2; exit 1; }
SWIFTC=$(command -v swiftc 2>/dev/null || xcrun --find swiftc)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "==> compiling"
"$SWIFTC" -swift-version 5 -O "$DIR/CodexStatus.swift" -o "$APP/Contents/MacOS/CodexStatus"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
# Ad-hoc sign so a locally-built app launches cleanly.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
