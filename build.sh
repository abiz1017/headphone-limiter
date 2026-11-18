#!/bin/bash
# Builds build/HeadphoneLimiter.app. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/HeadphoneLimiter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/HeadphoneLimiter" "$APP/Contents/MacOS/HeadphoneLimiter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Headphone Limiter</string>
    <key>CFBundleDisplayName</key><string>Headphone Limiter</string>
    <key>CFBundleIdentifier</key><string>local.headphone-limiter</string>
    <key>CFBundleExecutable</key><string>HeadphoneLimiter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Headphone Limiter routes audio headed for your headphones through itself so it can keep it below your limit.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/HeadphoneLimiter.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/HeadphoneLimiter.app"
fi
