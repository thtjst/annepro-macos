#!/usr/bin/env bash
# Builds AnnePro.app and the `anne` command-line tool as universal binaries
# (Apple Silicon + Intel) into dist/, signs them, and zips them for release.
#
#   scripts/build-app.sh                      # ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#   NOTARY_PROFILE=annepro scripts/build-app.sh   # also notarize (see docs/RELEASING.md)
#
# Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.thtjst.AnnePro}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
[[ "${UNIVERSAL:-1}" == "0" ]] && ARCH_FLAGS=()

DIST=dist
APP="$DIST/AnnePro.app"

echo "▸ Building $VERSION ($BUILD_NUMBER)"
swift build -c release "${ARCH_FLAGS[@]}" --product AnnePro
swift build -c release "${ARCH_FLAGS[@]}" --product anne
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AnnePro" "$APP/Contents/MacOS/AnnePro"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/AnnePro-Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN/anne" "$DIST/anne"
# Also inside the app, so the Homebrew cask can put `anne` on the PATH.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/anne" "$APP/Contents/Helpers/anne"

echo "▸ Signing ($([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
TIMESTAMP=(--timestamp=none)
[[ "$SIGN_IDENTITY" != "-" ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" "$DIST/anne"
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/anne"
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" \
    --entitlements Resources/AnnePro.entitlements "$APP"
codesign --verify --strict "$APP"

echo "▸ Packaging"
ditto -c -k --keepParent "$APP" "$DIST/AnnePro-$VERSION.zip"
(cd "$DIST" && zip -q "anne-$VERSION.zip" anne)

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ Notarizing"
    xcrun notarytool submit "$DIST/AnnePro-$VERSION.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/AnnePro-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$DIST/AnnePro-$VERSION.zip"
fi

echo "✓ $APP"
echo "✓ $DIST/AnnePro-$VERSION.zip"
echo "✓ $DIST/anne-$VERSION.zip"
