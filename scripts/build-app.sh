#!/usr/bin/env bash
# Builds "build/FloatChat.app" from the SwiftPM executable and codesigns it.
#
# Environment overrides:
#   BUNDLE_ID          CFBundleIdentifier            (default: dev.quickchat.omni)
#   VERSION            CFBundleShortVersionString    (default: latest git tag minus "v", else 0.0.0-dev)
#   BUILD_NUMBER       CFBundleVersion               (default: git commit count, else 1)
#   UNIVERSAL=1        build arm64 + x86_64 instead of the host architecture only
#   SPARKLE_FRAMEWORK  path to the official Sparkle.framework (optional)
#   SPARKLE_PUBLIC_KEY Ed25519 public key from Sparkle's generate_keys
#   SPARKLE_FEED_URL   HTTPS URL for the signed appcast
#   CODESIGN_IDENTITY  signing identity; "-" forces ad-hoc
#                      (default: configured local identity, then Apple Development, else ad-hoc)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FloatChat"
EXECUTABLE="FloatChat" # SwiftPM product name
# Preserve the existing preferences and WebKit website data across the rename.
BUNDLE_ID="${BUNDLE_ID:-dev.quickchat.omni}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"

SWIFT_FLAGS=(-c release)
if [ -n "${SWIFT_BUILD_FLAGS:-}" ]; then
  read -r -a extra_flags <<< "$SWIFT_BUILD_FLAGS"
  SWIFT_FLAGS+=("${extra_flags[@]}")
fi
if [ "${UNIVERSAL:-0}" = "1" ]; then
  SWIFT_FLAGS+=(--arch arm64 --arch x86_64)
fi

if [[ -n "${SPARKLE_FRAMEWORK:-}${SPARKLE_PUBLIC_KEY:-}${SPARKLE_FEED_URL:-}" ]]; then
  [[ "${SPARKLE_FRAMEWORK:-}" == */Sparkle.framework && -f "$SPARKLE_FRAMEWORK/Sparkle" ]] ||
    { echo 'Set SPARKLE_FRAMEWORK to the official Sparkle.framework.' >&2; exit 1; }
  [[ "${SPARKLE_PUBLIC_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ && "${SPARKLE_FEED_URL:-}" == https://* ]] ||
    { echo 'Sparkle needs an Ed25519 public key and an HTTPS feed URL.' >&2; exit 1; }
  codesign --verify --strict --deep "$SPARKLE_FRAMEWORK"
  FRAMEWORK_DIR="$(cd "$(dirname "$SPARKLE_FRAMEWORK")" && pwd)"
  SPARKLE_FRAMEWORK="$FRAMEWORK_DIR/Sparkle.framework"
  SWIFT_FLAGS+=(-Xswiftc -DFLOATCHAT_SPARKLE -Xswiftc -F -Xswiftc "$FRAMEWORK_DIR"
                -Xlinker -F -Xlinker "$FRAMEWORK_DIR"
                -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
fi

echo "==> swift build ${SWIFT_FLAGS[*]}"
swift build "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling ${APP} (${BUNDLE_ID} ${VERSION} (${BUILD_NUMBER}))"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${EXECUTABLE}" "${APP}/Contents/MacOS/${EXECUTABLE}"
cp -R Resources/Providers "${APP}/Contents/Resources/Providers"
cp Resources/AppIcon-FloatChat.icns "${APP}/Contents/Resources/AppIcon.icns" # regenerate with scripts/make-icon.sh

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>${APP_NAME} includes sound playing on your Mac in recordings you start.</string>
  <key>NSMicrophoneUsageDescription</key><string>${APP_NAME} uses the microphone for voice input and recordings you start.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>${APP_NAME} can show optional on-device captions for dictation you start.</string>
  <key>NSCameraUsageDescription</key><string>${APP_NAME} uses the camera when you take a photo or share video in a chat.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>${APP_NAME} saves files you download from a chat to your Downloads folder.</string>
</dict>
</plist>
PLIST
if [[ -n "${SPARKLE_FRAMEWORK:-}" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
  plist="$APP/Contents/Info.plist"
  plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$plist"
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$plist"
  plutil -insert SUEnableAutomaticChecks -bool YES "$plist"
  plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
  plutil -insert SURequireSignedFeed -bool YES "$plist"
fi
plutil -lint -s "${APP}/Contents/Info.plist"

# Prefer the identity recorded by the local installation. Fail clearly if it goes missing
# so a replacement never silently switches to ad-hoc and prompts for Keychain access again.
IDENTITY="${CODESIGN_IDENTITY:-}"
SIGN_KEYCHAIN=()
local_identity="$HOME/Library/Application Support/dev.quickchat.omni/local-signing.sha1"
if [[ -z "$IDENTITY" && -f "$local_identity" ]]; then
  IDENTITY="$(cat "$local_identity")"
  [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] ||
    { echo 'Invalid FloatChat local signing fingerprint.' >&2; exit 1; }
  SIGN_KEYCHAIN=(--keychain "$HOME/Library/Keychains/login.keychain-db")
fi
if [ -z "${IDENTITY}" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

# A secure timestamp needs the network and is only required for Developer ID (notarization).
TIMESTAMP="--timestamp=none"
case "${IDENTITY}" in "Developer ID Application"*) TIMESTAMP="--timestamp" ;; esac

echo "==> codesign (identity: ${IDENTITY})"
if [[ -n "${SPARKLE_FRAMEWORK:-}" ]]; then
  framework="$APP/Contents/Frameworks/Sparkle.framework"
  contents="$framework/Versions/Current"
  # Sign nested helpers before the framework so hardened runtime uses one team.
  for component in "$contents"/XPCServices/*.xpc "$contents/Updater.app" "$contents/Autoupdate" "$framework"; do
    codesign --force --options runtime "$TIMESTAMP" ${SIGN_KEYCHAIN[@]+"${SIGN_KEYCHAIN[@]}"} --sign "$IDENTITY" "$component"
  done
fi
codesign --force --options runtime "$TIMESTAMP" ${SIGN_KEYCHAIN[@]+"${SIGN_KEYCHAIN[@]}"} \
  --entitlements scripts/FloatChat.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"
echo "==> Built ${APP}"
