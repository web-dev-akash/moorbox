#!/bin/bash
# Builds Moorbox.app and a zip in dist/.
#
#   scripts/package-app.sh                  # native arch, ad-hoc signed
#   UNIVERSAL=1 scripts/package-app.sh      # arm64 + x86_64
#   CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=moorbox scripts/package-app.sh
#
# NOTARY_PROFILE is a keychain profile created with `xcrun notarytool store-credentials`.
# No credentials are read from or written to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST=dist
APP="$DIST/Moorbox.app"

if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Moorbox
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Moorbox"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Moorbox"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Moorbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-io.github.web-dev-akash.Moorbox}</string>
  <key>CFBundleName</key><string>Moorbox</string>
  <key>CFBundleDisplayName</key><string>Moorbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 The Moorbox Authors. Apache License 2.0.</string>
</dict>
</plist>
PLIST

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: runs locally, not distributable via Gatekeeper
fi
codesign --verify --strict "$APP"

ZIP="$DIST/Moorbox-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Built $APP ($VERSION build $BUILD)"
