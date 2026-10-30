#!/usr/bin/env bash
# Builds a Release "Fortify My Mac" (see build.sh), installs it into
# /Applications in place of any other copy, and opens it. Settings, the PIN and
# the Accessibility permission carry over (same bundle ID and signing identity).
# Usage: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$(./scripts/build.sh)"
APP="Fortify My Mac.app"

# Quit any running copy, including the old dev build and builds from before the rename.
pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
pkill -f "Fortify My Mac Dev.app/Contents/MacOS/" 2>/dev/null || true
pkill -f "AppLock.app/Contents/MacOS/AppLock" 2>/dev/null || true
sleep 1

# One copy only: they share a bundle ID, login item and permissions.
rm -rf "/Applications/$APP" "/Applications/Fortify My Mac Dev.app" /Applications/AppLock.app
ditto "$APP_PATH" "/Applications/$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
open "/Applications/$APP"
echo "Installed and opened /Applications/$APP"
