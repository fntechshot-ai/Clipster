#!/usr/bin/env bash
# Build via Xcode (requires full Xcode, not just Command Line Tools).
# For a no-Xcode build use ./build_noxcode.sh instead.
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project "Clipster.xcodeproj" -scheme "Clipster" -configuration Release -derivedDataPath build clean build
APP_PATH=$(find "build/Build/Products/Release" -maxdepth 1 -name "Clipster.app" -print -quit)
mkdir -p dist && cp -R "$APP_PATH" dist/
echo "Built dist/Clipster.app"
