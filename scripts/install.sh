#!/usr/bin/env bash
# Builds a Release "Fortify App Lock" (see build.sh), installs it into
# /Applications in place of any other copy, and opens it. Settings, the PIN and
# the Accessibility permission carry over (same bundle ID and signing identity).
# Usage: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$(./scripts/build.sh)"
APP="Fortify App Lock.app"

# Earlier names of the app; any copy left behind would share the bundle ID.
OLD=("Fortify My Mac.app" "Fortify My Mac Dev.app" "AppLock.app")

# Quit any running copy, including ones from before the renames.
for app in "$APP" "${OLD[@]}"; do
    pkill -f "$app/Contents/MacOS/" 2>/dev/null || true
done
sleep 1

# One copy only: they share a bundle ID, login item and permissions.
for app in "$APP" "${OLD[@]}"; do
    rm -rf "/Applications/$app"
done
ditto "$APP_PATH" "/Applications/$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
open "/Applications/$APP"
echo "Installed and opened /Applications/$APP"
