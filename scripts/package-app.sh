#!/bin/bash
# Builds a universal (arm64 + x86_64) Release Moorbox.app into dist/ and zips it.
#
# Open-source builds are ad-hoc signed (no Apple Developer ID). macOS asks users to approve
# the app once (System Settings → Privacy & Security → Open Anyway). To sign with a
# Developer ID instead, set CODESIGN_IDENTITY and DEVELOPMENT_TEAM.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DERIVED=.build/xcode-release
DIST=dist

MOORBOX_VERSION="$VERSION" MOORBOX_BUILD="$BUILD" xcodegen generate --quiet
set +o pipefail
xcodebuild -project Moorbox.xcodeproj -scheme Moorbox -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="${CODESIGN_IDENTITY:--}" DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  build 2>&1 | grep -E '^\*\*|error:|warning: [^M]'
set -o pipefail
APP_BUILT="$DERIVED/Build/Products/Release/Moorbox.app"
[[ -x "$APP_BUILT/Contents/MacOS/Moorbox" ]] || { echo "Release build failed" >&2; exit 1; }

rm -rf "$DIST/Moorbox.app"
mkdir -p "$DIST"
ditto "$APP_BUILT" "$DIST/Moorbox.app"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$DIST/Moorbox.app/Contents/Resources/"
# Re-sign after adding the notices so the signature covers them.
codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$DIST/Moorbox.app"
codesign --verify --strict "$DIST/Moorbox.app"
echo "Architectures: $(lipo -archs "$DIST/Moorbox.app/Contents/MacOS/Moorbox")"

ZIP="$DIST/Moorbox-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$DIST/Moorbox.app" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Built $DIST/Moorbox.app ($VERSION, build $BUILD) and $ZIP"
