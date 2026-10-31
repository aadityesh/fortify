#!/usr/bin/env bash
# Builds a Release "Fortify App Lock.app" into build/Release/ and prints its path.
#
# Signing uses the best identity on this Mac: Developer ID Application, then
# Apple Development, then ad-hoc ("-"), so anyone can build it. Override with
# SIGN_IDENTITY="Apple Development" (or "-") ./scripts/build.sh
#
# A stable identity matters: macOS ties the Accessibility permission to it, so
# an ad-hoc build has to be allowed again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="build/Release"
# Outside the repo: if it lives in an iCloud-synced folder (like ~/Documents),
# iCloud tags new folders with Finder info and codesign refuses to sign them.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FortifyAppLock-scripts"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if grep -q "Developer ID Application" <<<"$identities"; then
        SIGN_IDENTITY="Developer ID Application"
    elif grep -q "Apple Development" <<<"$identities"; then
        SIGN_IDENTITY="Apple Development"
    else
        SIGN_IDENTITY="-"
    fi
fi

signing=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # No Apple team needed.
    signing+=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
elif [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    # Automatic signing only signs for development; the app needs no
    # provisioning profile, so sign manually. Notarization requires a secure
    # timestamp and rejects the debugging entitlement (get-task-allow) that
    # Xcode otherwise injects into builds.
    signing+=(CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp"
              CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

echo "Building Fortify App Lock (Release, signed with: $SIGN_IDENTITY)…" >&2
xcodebuild -project AppLock.xcodeproj -scheme AppLock -configuration Release \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet \
    ONLY_ACTIVE_ARCH=NO "${signing[@]}" build >&2  # universal: Apple silicon and Intel

rm -rf "$OUT"
mkdir -p "$OUT"
ditto --noextattr --norsrc "$DERIVED/Build/Products/Release/Fortify App Lock.app" "$OUT/Fortify App Lock.app"
echo "$OUT/Fortify App Lock.app"
