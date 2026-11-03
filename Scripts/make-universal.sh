#!/bin/bash
# Builds a universal (arm64 + x86_64) Zapper.app and wraps it in a single
# .dmg for handing to another Mac. No CLI, no loose files — one draggable app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBJ="$ROOT/build/obj-universal"
APP="$ROOT/build/Zapper.app"
DMG="$ROOT/build/Zapper.dmg"

rm -rf "$OBJ"; mkdir -p "$OBJ"; cd "$OBJ"

for arch in arm64 x86_64; do
  echo "Building ATVKit ($arch)…"
  mkdir -p "$arch"
  swiftc -emit-module -module-name ATVKit -target ${arch}-apple-macosx13.0 \
         -emit-module-path "$arch/ATVKit.swiftmodule" \
         -emit-library -static -o "$arch/libATVKit.a" \
         "$ROOT"/Sources/ATVKit/*.swift

  echo "Building the app ($arch)…"
  swiftc -target ${arch}-apple-macosx13.0 -O \
         -I "$arch" -L "$arch" -lATVKit \
         -o ZapperApp-${arch} "$ROOT"/Sources/ZapperApp/*.swift
done

echo "Merging into a universal binary…"
lipo -create -output ZapperApp-universal ZapperApp-arm64 ZapperApp-x86_64
lipo -info ZapperApp-universal

echo "Assembling the bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ZapperApp-universal "$APP/Contents/MacOS/Zapper"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Zapper</string>
    <key>CFBundleDisplayName</key><string>Zapper</string>
    <!-- Predates the rename to Zapper. macOS ties granted permissions
         (Local Network, Screen Recording, Accessibility) to it. -->
    <key>CFBundleIdentifier</key><string>com.miremote.app</string>
    <key>CFBundleExecutable</key><string>Zapper</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Zapper finds and controls your TV devices on this network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_androidtvremote2._tcp</string>
        <string>_androidtvremote._tcp</string>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Packaging into a single .dmg…"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Zapper" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Universal app : $APP"
echo "Single file   : $DMG"
lipo -info "$APP/Contents/MacOS/Zapper"
