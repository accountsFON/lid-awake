#!/bin/sh
# Builds a universal (Apple Silicon + Intel) Lid Awake.app into build/ and
# zips it to dist/LidAwake.zip. Needs the Xcode Command Line Tools.
#   sh scripts/build.sh
# The version comes from VERSION, or LIDAWAKE_VERSION when set (release builds).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${LIDAWAKE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Lid Awake.app"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
for ARCH in arm64 x86_64; do
  swiftc -O -import-objc-header Sources/LidAwake/VirtualDisplay.h \
    -target "$ARCH-apple-macos13" -o "build/LidAwake-$ARCH" Sources/LidAwake/main.swift
done
lipo -create -output "$APP/Contents/MacOS/LidAwake" build/LidAwake-arm64 build/LidAwake-x86_64
cp Resources/watchdog.sh "$APP/Contents/Resources/watchdog.sh"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lid Awake</string>
  <key>CFBundleDisplayName</key><string>Lid Awake</string>
  <key>CFBundleIdentifier</key><string>com.fonmarketing.lidawake</string>
  <key>CFBundleExecutable</key><string>LidAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Made by Caleb Cody, Five One Nine Marketing. MIT License.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/LidAwake.zip
echo "Built Lid Awake $VERSION ($(lipo -archs "$APP/Contents/MacOS/LidAwake")) at dist/LidAwake.zip"
