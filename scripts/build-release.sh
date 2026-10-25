#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="${MACDRO_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${MACDRO_NOTARY_PROFILE:-}"
APP="$ROOT/dist/Macdro.app"
DMG="$ROOT/dist/Macdro.dmg"
BUILD_DIR="$ROOT/.build/xcode-release"

command -v xcodegen >/dev/null
xcodegen generate

xcodebuild \
    -project Macdro.xcodeproj \
    -scheme Macdro \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

PRODUCT="$BUILD_DIR/Build/Products/Release/Macdro.app"
test -d "$PRODUCT"
test -d "$PRODUCT/Contents/Resources/Macdro_MacdroKit.bundle"

ARCHS="$(lipo -archs "$PRODUCT/Contents/MacOS/Macdro")"
echo "Architectures: $ARCHS"
for arch in arm64 x86_64; do
    if [[ "$ARCHS" != *"$arch"* ]]; then
        echo "error: missing architecture $arch" >&2
        exit 1
    fi
done

rm -rf "$APP"
mkdir -p "$ROOT/dist"
ditto "$PRODUCT" "$APP"

CODESIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/macdro-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Macdro.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create \
    -volname "Macdro" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -quiet \
    "$DMG"
hdiutil verify "$DMG" >/dev/null
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "error: notarization requires MACDRO_SIGNING_IDENTITY" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

echo "App: $APP"
echo "DMG: $DMG"
echo "SHA256: $DMG.sha256"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signed ad hoc. Set MACDRO_SIGNING_IDENTITY for distribution."
else
    echo "Signed with $IDENTITY"
fi
