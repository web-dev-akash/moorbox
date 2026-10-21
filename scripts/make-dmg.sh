#!/bin/bash
# Wraps dist/Moorbox.app in a drag-to-Applications disk image (needs `brew install create-dmg`).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
DMG="dist/Moorbox-$VERSION.dmg"
[[ -d dist/Moorbox.app ]] || { echo "Run scripts/package-app.sh first." >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "create-dmg is required: brew install create-dmg" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto dist/Moorbox.app "$STAGE/Moorbox.app"
rm -f "$DMG"
create-dmg \
  --volname "Moorbox $VERSION" \
  --window-size 540 340 \
  --icon-size 112 \
  --icon "Moorbox.app" 140 160 \
  --app-drop-link 400 160 \
  --hide-extension "Moorbox.app" \
  --no-internet-enable \
  "$DMG" "$STAGE"
hdiutil verify "$DMG" >/dev/null
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG"
