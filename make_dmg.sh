#!/usr/bin/env bash
# Package dist/Clipster.app into a distributable DMG.
# Run ./build_noxcode.sh (or ./build.sh) first.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Clipster.app"
[ -d "$APP" ] || { echo "Build first: $APP not found"; exit 1; }

STAGE="buildtmp/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f dist/Clipster.dmg
hdiutil create -volname "Clipster" -srcfolder "$STAGE" -ov -format UDZO dist/Clipster.dmg
echo "Built dist/Clipster.dmg"
