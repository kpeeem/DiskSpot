#!/bin/zsh
# Usage: ./build.sh [Release|Debug]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-Release}"

xcodegen generate --quiet
xcodebuild \
  -project DiskSpot.xcodeproj \
  -scheme DiskSpot \
  -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  -quiet \
  build

PRODUCT="build/DerivedData/Build/Products/$CONFIG/DiskSpot.app"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/\)/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$PRODUCT"
fi

APP=build/DiskSpot.app
[[ "$CONFIG" == Release ]] || APP=build/DiskSpot-$CONFIG.app
rm -rf "$APP"
cp -R "$PRODUCT" "$APP"
echo "Готово: $(pwd)/$APP"
