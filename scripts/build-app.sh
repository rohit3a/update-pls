#!/bin/bash
# Builds "Update pls.app" into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/UpdatePls
APP="build/Update pls.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UpdatePls"
cp Sources/UpdatePls/Resources/catalog.json "$APP/Contents/Resources/"
VERSION=$(cat VERSION)
# Lets the app update itself from this clone.
SOURCE=""
[ -d .git ] && SOURCE="<key>UpdatePlsSource</key><string>$(pwd)</string>"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Update pls</string>
  <key>CFBundleDisplayName</key><string>Update pls</string>
  <key>CFBundleIdentifier</key><string>com.rohit3a.updatepls</string>
  <key>CFBundleExecutable</key><string>UpdatePls</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  $SOURCE
  <key>NSAppleEventsUsageDescription</key><string>Update pls asks apps to quit before it updates them.</string>
</dict>
</plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  # Reopened afterwards if it was running, so the menu bar icon doesn't just vanish.
  WAS_RUNNING=0
  if pgrep -f "/Update pls.app/Contents/MacOS/UpdatePls" >/dev/null; then WAS_RUNNING=1; fi
  osascript -e 'tell application id "com.rohit3a.updatepls" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "/Update pls.app/Contents/MacOS/UpdatePls" >/dev/null || break; sleep 0.1; done
  rm -rf "/Applications/Update pls.app"
  ditto "$APP" "/Applications/Update pls.app"
  echo "Installed to /Applications"
  if [ $WAS_RUNNING = 1 ]; then open -g "/Applications/Update pls.app"; echo "Reopened"; fi
fi
