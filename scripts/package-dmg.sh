#!/bin/sh
# Package an existing Codex Bar.app as a drag-to-Applications disk image.
# Usage: scripts/package-dmg.sh APP_PATH [OUTPUT_DIR] [ARCHITECTURE]
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:?"usage: scripts/package-dmg.sh APP_PATH [OUTPUT_DIR] [ARCHITECTURE]"}
OUTPUT_DIR=${2:-"$ROOT/dist"}
ARCH=${3:-$(uname -m)}

test -d "$APP"
test "$(basename "$APP")" = "Codex Bar.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
EXECUTABLE="$APP/Contents/MacOS/CodexBar"
NAME="Codex-Bar-$VERSION-macOS-$ARCH"
DMG="$OUTPUT_DIR/$NAME.dmg"
CHECKSUM="$DMG.sha256"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-bar-dmg.XXXXXX")
STAGING="$WORK_DIR/staging"
WRITABLE_DMG="$WORK_DIR/Codex-Bar-writable.dmg"
VOLUME_NAME="Codex Bar $VERSION"
MOUNTED=false
MOUNT_POINT=""

cleanup() {
  if [ "$MOUNTED" = true ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

command -v hdiutil >/dev/null 2>&1 || {
  echo "error: hdiutil is required to create a macOS disk image" >&2
  exit 1
}
test "$BUNDLE_ID" = "com.codexbar.app"
test -x "$EXECUTABLE"
codesign --verify --deep --strict "$APP"
/usr/bin/lipo "$EXECUTABLE" -verify_arch "$ARCH"

mkdir -p "$OUTPUT_DIR"
for artifact in "$DMG" "$CHECKSUM"; do
  [ ! -e "$artifact" ] || {
    echo "error: release artifact already exists: $artifact" >&2
    exit 1
  }
done

echo "==> staging drag-to-Applications disk image"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Codex Bar.app"
ln -s /Applications "$STAGING/Applications"
touch "$STAGING/.metadata_never_index"

if command -v sips >/dev/null 2>&1; then
  sips -s format png "$ROOT/docs/assets/dmg-background.svg" \
    --out "$STAGING/.background/background.png" >/dev/null 2>&1 || true
elif command -v qlmanage >/dev/null 2>&1; then
  qlmanage -t -s 660 -o "$WORK_DIR" "$ROOT/docs/assets/dmg-background.svg" >/dev/null 2>&1 || true
  if [ -f "$WORK_DIR/dmg-background.svg.png" ]; then
    cp "$WORK_DIR/dmg-background.svg.png" "$STAGING/.background/background.png"
  fi
fi

echo "==> creating compressed DMG"
hdiutil create -quiet -volname "$VOLUME_NAME" -fs HFS+ -srcfolder "$STAGING" \
  -format UDRW "$WRITABLE_DMG"
ATTACH_OUTPUT=$(hdiutil attach "$WRITABLE_DMG" -readwrite -nobrowse)
MOUNT_POINT=$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS/ { print $NF; exit }')
test -n "$MOUNT_POINT"
MOUNTED=true

if [ -f "$MOUNT_POINT/.background/background.png" ]; then
  if osascript >/dev/null 2>"$WORK_DIR/finder-layout.log" <<EOF
set backgroundFile to POSIX file "$MOUNT_POINT/.background/background.png" as alias
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set pathbar visible to false
      set bounds to {120, 120, 780, 520}
    end tell
    tell icon view options of container window
      set arrangement to not arranged
      set icon size to 112
      set text size to 13
      set background picture to backgroundFile
    end tell
    set position of item "Codex Bar.app" to {190, 210}
    set position of item "Applications" to {470, 210}
    close
    update without registering applications
    delay 1
  end tell
end tell
EOF
  then
    echo "==> applied branded Finder layout"
  else
    echo "warning: Finder layout could not be applied; using the standard icon layout" >&2
    sed 's/^/warning: /' "$WORK_DIR/finder-layout.log" >&2
  fi
fi

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=false
hdiutil convert -quiet "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
hdiutil verify "$DMG" >/dev/null

echo "==> writing DMG SHA-256 checksum"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")"
)

echo "dmg: $DMG"
echo "dmg checksum: $CHECKSUM"
echo "version: $VERSION"
echo "architecture: $ARCH"
