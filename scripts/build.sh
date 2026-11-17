#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/tailscale-route.app"

cd "$ROOT_DIR"
swift build -c release --product tailscale-route
swift build -c release --product tailscale-route-helper

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Library/LaunchDaemons" \
  "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/AppInfo.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/com.tailscale-route.helper.plist" "$APP_DIR/Contents/Library/LaunchDaemons/com.tailscale-route.helper.plist"
cp "$BUILD_DIR/out/Products/Release/tailscale-route" "$APP_DIR/Contents/MacOS/tailscale-route"
cp "$BUILD_DIR/out/Products/Release/tailscale-route-helper" "$APP_DIR/Contents/MacOS/tailscale-route-helper"
chmod 755 "$APP_DIR/Contents/MacOS/tailscale-route" "$APP_DIR/Contents/MacOS/tailscale-route-helper"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/MacOS/tailscale-route-helper"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
  # Finder/LaunchServices can reject a manually assembled bundle whose
  # executable is only linker-signed. Ad-hoc sign the complete bundle for
  # local development; production builds should provide CODESIGN_IDENTITY.
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "已生成：$APP_DIR"
