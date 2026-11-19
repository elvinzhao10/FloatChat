#!/usr/bin/env bash
# Packages an already-built app. Set NOTARY_PROFILE and CODESIGN_IDENTITY for a Developer ID release.
set -euo pipefail
cd "$(dirname "$0")/.."
APP='build/FloatChat.app'
OUTPUT_DIR="${FLOATCHAT_DIST_DIR:-dist}"
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo 'Invalid version'; exit 1; }
[[ "$VERSION" == "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" ]] || { echo 'Bundle version does not match package version'; exit 1; }
codesign --verify --strict --deep "$APP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/disk" "$WORK/assets"
staged="$WORK/disk/FloatChat.app"
ditto "$APP" "$staged"
ln -s /Applications "$WORK/disk/Applications"
NAME="FloatChat-$VERSION"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "${CODESIGN_IDENTITY:-}" == 'Developer ID Application:'* ]] ||
        { echo 'Notarization needs a Developer ID Application identity.' >&2; exit 1; }
    codesign -dv --verbose=4 "$staged" 2>&1 | grep -Fx "Authority=$CODESIGN_IDENTITY"
    ditto -c -k --sequesterRsrc --keepParent "$staged" "$WORK/submission.zip"
    xcrun notarytool submit "$WORK/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$staged"
    xcrun stapler validate "$staged"
elif plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo 'Configure notarization before packaging an update-enabled release.' >&2
    exit 1
fi

cat > "$WORK/disk/Start Here.txt" <<'TEXT'
FloatChat

Drag FloatChat into Applications, then open it there.
Choose a logo to switch websites. Use the menu icon to add or arrange websites.
TEXT
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    cat >> "$WORK/disk/Start Here.txt" <<'TEXT'

This community build is distributed without Apple notarization. If macOS blocks
the first launch, verify the download came from the official GitHub release and
check System Settings > Privacy & Security for FloatChat.
TEXT
fi
ditto -c -k --sequesterRsrc --keepParent "$staged" "$WORK/assets/$NAME.zip"
dmg="$WORK/assets/$NAME.dmg"
hdiutil create -volname 'FloatChat' -srcfolder "$WORK/disk" -format UDZO "$dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    codesign --sign "$CODESIGN_IDENTITY" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi
hdiutil verify "$dmg"
ditto -x -k "$WORK/assets/$NAME.zip" "$WORK/verify"
codesign --verify --strict --deep "$WORK/verify/FloatChat.app"
(cd "$WORK/assets" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME.sha256")
mkdir -p "$OUTPUT_DIR"
mv "$WORK/assets/"* "$OUTPUT_DIR/"
echo "Packaged $OUTPUT_DIR/$NAME.zip and $OUTPUT_DIR/$NAME.dmg"
