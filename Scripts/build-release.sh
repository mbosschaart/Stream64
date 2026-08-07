#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.107b}"
BUILD_NUMBER="${BUILD_NUMBER:-106}"
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

# The app bundle is assembled and ad-hoc signed in a local scratch directory
# rather than directly under OUTPUT_DIR. When OUTPUT_DIR lives inside iCloud
# Drive (as it does for this project's dist/ folder), the iCloud file-provider
# daemon can tag a freshly-created bundle directory with a com.apple.FinderInfo
# xattr while it's being assembled/signed, which makes `codesign --verify
# --strict` fail intermittently ("resource fork, Finder information, or
# similar detritus not allowed"). Building in /tmp avoids that race entirely;
# only the finished, sealed .zip/.dmg/checksum files are written to OUTPUT_DIR.
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stream64-build-$ARCH.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
DMG_ROOT="$STAGE_DIR/.dmg-root"

ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH-SHA256.txt"

echo "Building $APP_NAME $VERSION ($BUILD_NUMBER) for macOS $ARCH..."
swift build --package-path "$ROOT_DIR" -c release --triple "$TRIPLE"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release \
    --triple "$TRIPLE" --show-bin-path)"

mkdir -p "$OUTPUT_DIR"
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
cp "$ROOT_DIR/NOTICE" "$APP_BUNDLE/Contents/Resources/NOTICE"

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
xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
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

# Copy the finished, already-signed app bundle to OUTPUT_DIR purely for local
# convenience (e.g. quick manual testing). This copy is not a distribution
# artifact — only the .zip/.dmg above are — so it's fine if iCloud later tags
# it with xattrs that would fail a strict codesign verify.
rm -rf "$OUTPUT_DIR/$APP_NAME.app"
ditto "$APP_BUNDLE" "$OUTPUT_DIR/$APP_NAME.app"

echo
echo "Release artifacts:"
echo "  App: $OUTPUT_DIR/$APP_NAME.app"
echo "  ZIP: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
echo "  SHA: $CHECKSUM_PATH"
echo
echo "This is ad-hoc signed, not notarized. Downloaded copies still require"
echo "Control-click -> Open (or approval in Privacy & Security) on first launch."
