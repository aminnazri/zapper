#!/bin/bash
# Packages Zapper.app into a drag-to-install disk image.
#
#   Scripts/make-dmg.sh [path/to/Zapper.app] [output.dmg]
#
# Defaults to build/Zapper.app and build/Zapper-macOS.dmg. The image opens to
# a window with the app on the left and an Applications shortcut on the right.
# Uses only hdiutil and Finder, both built in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Zapper.app}"
OUT="${2:-$ROOT/build/Zapper-macOS.dmg}"
VOLUME="Zapper"

[ -d "$APP" ] || { echo "no app at $APP — run Scripts/make-app.sh first"; exit 1; }

WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Zapper.app"
ln -s /Applications "$STAGE/Applications"

# A writable image first, so Finder can save the window layout into it.
hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
        -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen -readwrite "$WORK/rw.dmg"

# Lay out the window. Needs permission for this terminal to control Finder;
# without it the image still works, just with Finder's default layout.
osascript <<APPLESCRIPT || echo "note: couldn't set the window layout (Finder automation denied); using defaults"
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 740, 460}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set position of item "Zapper.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach -quiet "/Volumes/$VOLUME"

# Compress into the final read-only image.
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
echo "Built $OUT"
