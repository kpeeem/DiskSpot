#!/bin/zsh
# Usage: ./build-mcp.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product diskspotmcp

mkdir -p build
cp .build/release/diskspotmcp build/diskspotmcp

# Ad-hoc signatures change on every build and macOS then forgets the Full Disk Access grant.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/\)/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" build/diskspotmcp
fi
echo "Готово: $(pwd)/build/diskspotmcp"
