#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/AppInfo.plist")"
ARM_BUILD_PATH="$ROOT_DIR/.build/release-arm64"
INTEL_BUILD_PATH="$ROOT_DIR/.build/release-x86_64"
ARM_PRODUCTS="$ARM_BUILD_PATH/out/Products/Release"
INTEL_PRODUCTS="$INTEL_BUILD_PATH/out/Products/Release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/tailscale-route.app"
DMG_PATH="$DIST_DIR/tailscale-route-$VERSION-universal.dmg"

cd "$ROOT_DIR"

swift build -c release --triple arm64-apple-macosx13.0 --build-path "$ARM_BUILD_PATH" --product tailscale-route
swift build -c release --triple arm64-apple-macosx13.0 --build-path "$ARM_BUILD_PATH" --product tailscale-route-helper
swift build -c release --triple x86_64-apple-macosx13.0 --build-path "$INTEL_BUILD_PATH" --product tailscale-route
swift build -c release --triple x86_64-apple-macosx13.0 --build-path "$INTEL_BUILD_PATH" --product tailscale-route-helper

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Library/LaunchDaemons" \
  "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/AppInfo.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/com.tailscale-route.helper.plist" "$APP_DIR/Contents/Library/LaunchDaemons/com.tailscale-route.helper.plist"
xcrun lipo -create \
  "$ARM_PRODUCTS/tailscale-route" \
  "$INTEL_PRODUCTS/tailscale-route" \
  -output "$APP_DIR/Contents/MacOS/tailscale-route"
xcrun lipo -create \
  "$ARM_PRODUCTS/tailscale-route-helper" \
  "$INTEL_PRODUCTS/tailscale-route-helper" \
  -output "$APP_DIR/Contents/MacOS/tailscale-route-helper"
chmod 755 "$APP_DIR/Contents/MacOS/tailscale-route" "$APP_DIR/Contents/MacOS/tailscale-route-helper"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/MacOS/tailscale-route-helper"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

APP_ARCHS="$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/tailscale-route")"
HELPER_ARCHS="$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/tailscale-route-helper")"
if [[ "$APP_ARCHS" != *arm64* || "$APP_ARCHS" != *x86_64* || "$HELPER_ARCHS" != *arm64* || "$HELPER_ARCHS" != *x86_64* ]]; then
  print -u2 "Universal binary check failed: App=[$APP_ARCHS], Helper=[$HELPER_ARCHS]"
  exit 1
fi

STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/tailscale-route.app"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
  -volname "tailscale-route $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    print -u2 "NOTARY_PROFILE requires a Developer ID CODESIGN_IDENTITY."
    exit 1
  fi
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
else
  print "Warning: this DMG is ad-hoc signed and not notarized."
fi

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
print "Created: $DMG_PATH"
print "SHA-256: $(awk '{print $1}' "$DMG_PATH.sha256")"
