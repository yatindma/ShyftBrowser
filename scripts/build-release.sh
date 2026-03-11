#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(cat "$ROOT/VERSION" | tr -d '[:space:]')

echo "Building ShyftBrowser v${VERSION}..."

# 1. Build release binary
swift build --package-path "$ROOT/Shyft" -c release

# 2. Update Info.plist with version from VERSION file
PLIST="$ROOT/Shyft.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"

# 3. Copy binary into .app bundle
cp "$ROOT/Shyft/.build/release/Shyft" "$ROOT/Shyft.app/Contents/MacOS/Shyft"

# 4. Create DMG
rm -f "$ROOT/ShyftBrowser.dmg"
hdiutil create -volname "ShyftBrowser" -srcfolder "$ROOT/Shyft.app" -ov -format UDZO "$ROOT/ShyftBrowser.dmg"

echo "Done! ShyftBrowser v${VERSION} → ShyftBrowser.dmg"
