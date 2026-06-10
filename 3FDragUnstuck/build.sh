#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/../build"
APP_DIR="$BUILD_DIR/3FDragUnstuck.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

clang \
  -arch arm64 \
  -fobjc-arc \
  -mmacosx-version-min=13.0 \
  "$ROOT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/3FDragUnstuck" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework CoreFoundation

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
