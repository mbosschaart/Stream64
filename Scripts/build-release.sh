#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.99b}"
BUILD_NUMBER="${BUILD_NUMBER:-99}"
ARCH="${ARCH:-arm64}"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported ARCH '$ARCH' (expected arm64 or x86_64)." >&2
        exit 2
        ;;
esac
TRIPLE="$ARCH-apple-macosx14.0"
OUTPUT_DIR="${OUTPUT_DIR:-"$ROOT_DIR/dist/$ARCH"}"
APP_NAME="Stream64"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH-SHA256.txt"
DMG_ROOT="$OUTPUT_DIR/.dmg-root"

echo "Building $APP_NAME $VERSION ($BUILD_NUMBER) for macOS $ARCH..."
swift build --package-path "$ROOT_DIR" -c release --triple "$TRIPLE"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release \
    --triple "$TRIPLE" --show-bin-path)"

rm -rf "$APP_BUNDLE" "$DMG_ROOT"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

install -m 755 "$BIN_DIR/Stream64" "$APP_BUNDLE/Contents/MacOS/Stream64"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Packaging/Stream64.icns" \
    "$APP_BUNDLE/Contents/Resources/Stream64.icns"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP_BUNDLE/Contents/Info.plist"

# App-bundle releases use standard Contents/Resources lookup. `swift run`
# continues to use SwiftPM's generated Bundle.module fallback.
cp "$BIN_DIR/Stream64_Stream64.bundle/dirty-glass-mask.png" \
    "$APP_BUNDLE/Contents/Resources/dirty-glass-mask.png"
cp "$BIN_DIR/Stream64_Stream64.bundle/logofactuur.png" \
    "$APP_BUNDLE/Contents/Resources/logofactuur.png"
cp "$BIN_DIR/Stream64_Stream64.bundle/Stream64logo.png" \
    "$APP_BUNDLE/Contents/Resources/Stream64logo.png"
if [[ -f "$BIN_DIR/ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy" ]]; then
    cp "$BIN_DIR/ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy" \
        "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
fi

cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
file "$APP_BUNDLE/Contents/MacOS/Stream64"
ACTUAL_ARCH="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Stream64")"
if [[ "$ACTUAL_ARCH" != "$ARCH" ]]; then
    echo "Expected $ARCH binary, got: $ACTUAL_ARCH" >&2
    exit 3
fi

echo "Applying ad-hoc signature..."
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Creating ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Creating DMG..."
mkdir -p "$DMG_ROOT"
ditto "$APP_BUNDLE" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
codesign --force --sign - "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
rm -rf "$DMG_ROOT"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 \
        "$(basename "$ZIP_PATH")" \
        "$(basename "$DMG_PATH")" \
        > "$(basename "$CHECKSUM_PATH")"
)

echo
echo "Release artifacts:"
echo "  App: $APP_BUNDLE"
echo "  ZIP: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
echo "  SHA: $CHECKSUM_PATH"
echo
echo "This is ad-hoc signed, not notarized. Downloaded copies still require"
echo "Control-click -> Open (or approval in Privacy & Security) on first launch."
