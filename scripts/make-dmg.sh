#!/usr/bin/env bash
# Builds a Release "Fortify App Lock" (see build.sh) and packs it into
# build/Fortify-App-Lock-<version>.dmg: the app next to an Applications shortcut,
# so installing is a drag. Prints the DMG's path and SHA-256.
#
# With a Developer ID build, the DMG is also notarized by Apple and the ticket
# stapled, so it opens without a Gatekeeper warning. That needs notarytool
# credentials saved once under NOTARY_PROFILE (default "fortify-notary"):
#   xcrun notarytool store-credentials fortify-notary --apple-id <email> --team-id <team>
# Usage: ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$(./scripts/build.sh)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG="build/Fortify-App-Lock-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto --noextattr --norsrc "$APP_PATH" "$STAGING/Fortify App Lock.app"  # drop iCloud's Finder info
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Fortify App Lock" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"

# Sign the image with the app's identity, unless the app is ad-hoc signed.
identity="$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "$identity" ]]; then
    codesign --force --timestamp --sign "$identity" "$DMG"
fi

if [[ "$identity" == "Developer ID Application"* ]]; then
    echo "Notarizing (usually a few minutes)…" >&2
    profile="${NOTARY_PROFILE:-fortify-notary}"
    result="$(xcrun notarytool submit "$DMG" --keychain-profile "$profile" --wait)"
    echo "$result" >&2
    if ! grep -q "status: Accepted" <<<"$result"; then
        # notarytool exits 0 even when Apple rejects the image; show why.
        id="$(sed -n 's/^ *id: //p' <<<"$result" | head -1)"
        xcrun notarytool log "$id" --keychain-profile "$profile" >&2
        echo "Notarization failed." >&2
        exit 1
    fi
    xcrun stapler staple "$DMG" >&2
    spctl --assess --type open --context context:primary-signature -v "$DMG" >&2
fi

echo "$DMG"
shasum -a 256 "$DMG"
