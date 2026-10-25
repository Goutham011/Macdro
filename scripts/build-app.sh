#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"

SWIFT_FLAGS=()
SWIFTUI_PLUGIN_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [[ -d "$SWIFTUI_PLUGIN_PATH" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$SWIFTUI_PLUGIN_PATH")
fi

swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)"

APP="$ROOT/dist/Macdro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Macdro" "$APP/Contents/MacOS/Macdro"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

RESOURCE_BUNDLE="$APP/Contents/Resources/Macdro_MacdroKit.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "error: Macdro resource bundle was not packaged" >&2
    exit 1
fi

IDENTITY="${MACDRO_SIGNING_IDENTITY:--}"
CODESIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    CODESIGN_FLAGS+=(--options runtime --timestamp)
fi
codesign "${CODESIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

NOTARY_PROFILE="${MACDRO_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "error: notarization requires MACDRO_SIGNING_IDENTITY" >&2
        exit 1
    fi
    ZIP="$ROOT/dist/Macdro.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

echo "Built $APP"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signed ad hoc. Set MACDRO_SIGNING_IDENTITY for distribution."
else
    echo "Signed with $IDENTITY"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarized with profile $NOTARY_PROFILE"
fi
echo "Run with: open \"$APP\""
