#!/bin/bash
# Builds Zapper.app.
#
# Uses swiftc directly rather than SwiftPM, because this machine's SwiftPM
# manifest library is broken (see README "Toolchain"). The package has no
# external dependencies, so a direct compile is equivalent. Once `swift build`
# works you can use it instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="x86_64-apple-macosx13.0"
OBJ="$ROOT/build/obj"
APP="$ROOT/build/Zapper.app"

case "$(uname -m)" in arm64) TARGET="arm64-apple-macosx13.0" ;; esac

rm -rf "$OBJ"; mkdir -p "$OBJ"
cd "$OBJ"

echo "Building ATVKit…"
swiftc -emit-module -module-name ATVKit -target "$TARGET" \
       -emit-module-path ATVKit.swiftmodule \
       -emit-library -static -o libATVKit.a \
       $(find "$ROOT/Sources/ATVKit" -name '*.swift')

echo "Building ZapperApp…"
swiftc -target "$TARGET" -I . -L . -lATVKit -O \
       -o ZapperApp "$ROOT"/Sources/ZapperApp/*.swift

echo "Building zapper CLI…"
swiftc -target "$TARGET" -I . -L . -lATVKit -O \
       -o zapper "$ROOT"/Sources/zapper/main.swift

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ZapperApp "$APP/Contents/MacOS/Zapper"
cp zapper "$ROOT/build/zapper"
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
    <key>NSAppleEventsUsageDescription</key>
    <string>Zapper reads the address of a browser tab you share, so a YouTube video can play in the TV's own YouTube app.</string>
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

# Screen Recording and Accessibility grants are tied to the signature. An
# ad-hoc signature changes with every build, so each rebuild silently lost
# them (System Settings still shows the switch on, for the old build). A
# stable certificate keeps them. Create it once with Scripts/make-signing-identity.sh.
# The certificate keeps its pre-rename name: renaming it would change the
# signature and lose the grants all over again.
IDENTITY="${ZAPPER_SIGN_IDENTITY:-${MIREMOTE_SIGN_IDENTITY:-MiRemote Local Signing}}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP" || \
        echo "warning: codesign with \"$IDENTITY\" failed"
else
    echo "note: no \"$IDENTITY\" identity; signing ad hoc. Permissions will need"
    echo "      re-granting after every build — run Scripts/make-signing-identity.sh."
    codesign --force --deep --sign - "$APP" 2>/dev/null || \
        echo "warning: codesign failed — Local Network permission may not be granted"
fi

echo
echo "Built $APP"
echo "  GUI: open \"$APP\""
echo "  CLI: $ROOT/build/zapper discover"
