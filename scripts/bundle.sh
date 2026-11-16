#!/usr/bin/env bash
# Builds build/mypetil.app (menu-bar only, no Dock icon).
#
# macOS ties the Accessibility permission to the code signature. An ad-hoc signature
# is just a hash of the binary, so every rebuild would look like a new app and the
# permission would silently stop working. Signing with a real certificate keeps the
# identity stable across rebuilds. Override with MYPETIL_SIGN_IDENTITY=<name or hash>.
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
IDENTITY="${MYPETIL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk '/"Apple Development:/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
    echo "warning: no signing certificate found, signing ad-hoc." >&2
    echo "         The Accessibility permission must be re-granted after every rebuild." >&2
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
