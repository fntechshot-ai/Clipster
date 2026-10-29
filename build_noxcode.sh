#!/usr/bin/env bash
# Build Clipster.app without Xcode (uses swiftc + iconutil from Command Line Tools).
# Produces dist/Clipster.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Clipster"
BUNDLE_ID="com.francisconeto.Clipster"
SRC="Clipster"
OUT="dist/${APP_NAME}.app"
MIN_MACOS="13.0"

echo "==> Cleaning"
rm -rf dist buildtmp
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources" buildtmp

ARCH="$(uname -m)"   # arm64 or x86_64
echo "==> Compiling Swift sources (${ARCH})"
swiftc -O \
  "${SRC}/ClipsterApp.swift" "${SRC}/ClipboardManager.swift" \
  "${SRC}/ContentView.swift" "${SRC}/HotKey.swift" \
  -o "${OUT}/Contents/MacOS/${APP_NAME}" \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -framework SwiftUI -framework AppKit -framework Carbon \
  -framework Cocoa -framework UniformTypeIdentifiers

echo "==> Building app icon (.icns)"
ICONSET_SRC="${SRC}/Assets.xcassets/AppIcon.appiconset"
if [ -d "${ICONSET_SRC}" ]; then
  ICONSET="buildtmp/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  for f in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x \
           icon_128x128 icon_128x128@2x icon_256x256 icon_256x256@2x \
           icon_512x512 icon_512x512@2x; do
    [ -f "${ICONSET_SRC}/${f}.png" ] && cp "${ICONSET_SRC}/${f}.png" "${ICONSET}/${f}.png"
  done
  iconutil -c icns "${ICONSET}" -o "${OUT}/Contents/Resources/AppIcon.icns"
fi

echo "==> Writing Info.plist"
cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${OUT}" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: ${OUT}"
