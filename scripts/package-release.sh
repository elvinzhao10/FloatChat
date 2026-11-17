#!/usr/bin/env bash
# Packages an already-built app. No credentials or network access required.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw 'build/Quick Chat Omni.app/Contents/Info.plist')}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo 'Invalid version'; exit 1; }
APP='build/Quick Chat Omni.app'
codesign --verify --strict --deep "$APP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p dist "$WORK/disk"
ditto "$APP" "$WORK/disk/Quick Chat Omni.app"
ln -s /Applications "$WORK/disk/Applications"
cat > "$WORK/disk/Start Here.txt" <<'TEXT'
Quick Chat Omni

Drag Quick Chat Omni into Applications, then open it there.
Choose a logo to switch websites. Use the menu icon to add or arrange websites.

This community build is not notarized by Apple. If macOS blocks the first launch,
open System Settings > Privacy & Security, then choose Open Anyway for Quick Chat Omni.
Only approve an app downloaded from the project's official GitHub release.
TEXT
NAME="Quick-Chat-Omni-$VERSION"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"
hdiutil create -volname 'Quick Chat Omni' -srcfolder "$WORK/disk" -format UDZO -ov "dist/$NAME.dmg"
hdiutil verify "dist/$NAME.dmg"
ditto -x -k "dist/$NAME.zip" "$WORK/verify"
codesign --verify --strict --deep "$WORK/verify/Quick Chat Omni.app"
(cd dist && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME.sha256")
echo "Packaged dist/$NAME.zip and dist/$NAME.dmg"
