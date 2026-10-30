#!/usr/bin/env bash
# Builds a Release "Fortify My Mac" (see build.sh) and packs it into
# build/Fortify-My-Mac-<version>.dmg: the app next to an Applications shortcut,
# so installing is a drag. Prints the DMG's path and SHA-256.
# Usage: ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$(./scripts/build.sh)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG="build/Fortify-My-Mac-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP_PATH" "$STAGING/Fortify My Mac.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Fortify My Mac" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"

# Sign the image with the app's identity, unless the app is ad-hoc signed.
identity="$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" "$DMG"
fi

echo "$DMG"
shasum -a 256 "$DMG"
