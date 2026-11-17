#!/bin/bash
# Packages the generated Omni artwork into a macOS icon.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sips -z 1024 1024 "${1:-Resources/AppIcon-Omni.png}" --out "${WORK}/icon_1024.png" >/dev/null
SET="${WORK}/AppIcon.iconset"
mkdir -p "${SET}"
for s in 16 32 128 256 512; do
  sips -z $s $s "${WORK}/icon_1024.png" --out "${SET}/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "${WORK}/icon_1024.png" --out "${SET}/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "${SET}" -o Resources/AppIcon-Omni.icns
cp "${WORK}/icon_1024.png" Resources/AppIcon-Omni-1024.png
echo "==> Resources/AppIcon-Omni.icns"
