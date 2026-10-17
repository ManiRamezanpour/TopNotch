#!/bin/zsh
# Build TopNotch.app and install to /Applications. Usage: ./build.sh
set -e
cd "${0:a:h}"
swift build -c release
APP=/Applications/TopNotch.app
pkill -x TopNotch || true
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TopNotch "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.arshia.topnotch</string>
  <key>CFBundleName</key><string>TopNotch</string>
  <key>CFBundleExecutable</key><string>TopNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>TopNotch controls Spotify and Music.</string>
</dict></plist>
PLIST
# stable identity => macOS keeps Full Disk Access / Automation grants across rebuilds; ad-hoc fallback elsewhere
ID="TopNotch Dev"; security find-identity -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"
open "$APP"
echo "running: $APP"
