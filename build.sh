#!/bin/bash
# Builds AppMixer.app into ./build — a universal app (Apple silicon + Intel).
#   ./build.sh         build the app
#   ./build.sh --dmg   build the app and package dist/AppMixer-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64

APP=build/AppMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/AppMixer "$APP/Contents/MacOS/AppMixer"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature with an identifier-based requirement, so macOS keeps privacy permissions
# (audio capture) across rebuilds instead of tying them to each build's hash.
codesign --force --sign - --identifier studio.b1t.appmixer \
  -r='designated => identifier "studio.b1t.appmixer"' "$APP"

echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "dmg/How to open AppMixer.txt" "$STAGE/"
  mkdir -p dist
  DMG="dist/AppMixer-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname "AppMixer $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Packaged $(pwd)/$DMG"
fi
