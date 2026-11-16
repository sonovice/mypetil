#!/usr/bin/env bash
# Builds build/mypetil.app (menu-bar only, no Dock icon).
# An app bundle keeps a stable identity for the Accessibility permission;
# `swift run` would attribute the permission to your terminal instead.
set -euo pipefail
cd "$(dirname "$0")/.."

xcrun swift build -c release
APP=build/mypetil.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/mypetil "$APP/Contents/MacOS/mypetil"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.sonovice.mypetil</string>
    <key>CFBundleName</key><string>mypetil</string>
    <key>CFBundleExecutable</key><string>mypetil</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
