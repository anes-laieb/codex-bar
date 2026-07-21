#!/bin/sh
# Build, validate, and package the current Codex Bar version for GitHub Releases.
# Usage: scripts/package-release.sh [OUTPUT_DIR]
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${1:-"$ROOT/dist"}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Info.plist")
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/app/Info.plist")
ARCH=$(uname -m)
NAME="Codex-Bar-$VERSION-macOS-$ARCH"
ARCHIVE="$OUTPUT_DIR/$NAME.zip"
CHECKSUM="$ARCHIVE.sha256"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-bar-release.XXXXXX")

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT_DIR"
[ ! -e "$ARCHIVE" ] || {
  echo "error: release archive already exists: $ARCHIVE" >&2
  exit 1
}
[ ! -e "$CHECKSUM" ] || {
  echo "error: checksum already exists: $CHECKSUM" >&2
  exit 1
}

echo "==> building Codex Bar $VERSION for $ARCH"
sh "$ROOT/app/build.sh" "$BUILD_DIR"
APP="$BUILD_DIR/Codex Bar.app"

echo "==> validating bundle"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/NOTICE"
test -d "$APP/Contents/Resources/StatusAssets"

echo "==> creating release archive"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
unzip -tq "$ARCHIVE"

echo "==> writing SHA-256 checksum"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)

echo "release: $ARCHIVE"
echo "checksum: $CHECKSUM"
echo "version: $VERSION"
echo "architecture: $ARCH"
echo "minimum macOS: $MIN_MACOS"
