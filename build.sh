#!/bin/zsh
# Builds Prayer Island.app and installs it to /Applications (or ~/Applications if that is not writable).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Prayer Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PrayerIsland "$APP/Contents/MacOS/PrayerIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A stable local identity keeps macOS permissions (Calendar, Location) across rebuilds; ad-hoc resets them.
IDENTITY=$(security find-identity -p codesigning | awk '/"Prayer Island Dev"/ {print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" --entitlements Resources/PrayerIsland.entitlements "$APP"

DEST=/Applications; [[ -w $DEST ]] || DEST=~/Applications
pkill -x PrayerIsland 2>/dev/null || true
rm -rf ~/Applications/"Prayer Island.app" "$DEST/Prayer Island.app"
cp -R "$APP" "$DEST/"
echo "Installed to $DEST/Prayer Island.app"
