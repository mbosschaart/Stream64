#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.128b}"
BUILD_NUMBER="${BUILD_NUMBER:-128}"
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

# Optional local secrets (never commit): APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD,
# APPLE_TEAM_ID, CODESIGN_IDENTITY.
if [[ -f "$ROOT_DIR/.notarize.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.notarize.env"
fi

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Martijn Bosschaart (EJ77LX9A8T)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-EJ77LX9A8T}"
# SIGNING=adhoc skips notarization (legacy local smoke builds).
SIGNING="${SIGNING:-developer-id}"
ENTITLEMENTS="$ROOT_DIR/Packaging/entitlements.plist"

# The app bundle is assembled and signed in a local scratch directory
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
NOTARIZE_ZIP="$STAGE_DIR/$APP_NAME-notarize.zip"

ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION-macos-$ARCH-SHA256.txt"

require_notarize_credentials() {
    local missing=()
    [[ -n "${APPLE_ID:-}" ]] || missing+=("APPLE_ID")
    [[ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || missing+=("APPLE_APP_SPECIFIC_PASSWORD")
    [[ -n "${APPLE_TEAM_ID:-}" ]] || missing+=("APPLE_TEAM_ID")
    if ((${#missing[@]} > 0)); then
        echo "Missing notarization credentials: ${missing[*]}" >&2
        echo "Create a gitignored .notarize.env with APPLE_ID," >&2
        echo "APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID," >&2
        echo "or export those variables in your shell." >&2
        exit 4
    fi
}

sign_app_developer_id() {
    echo "Signing with $CODESIGN_IDENTITY..."
    chmod -R u+w "$APP_BUNDLE"
    xattr -cr "$APP_BUNDLE"
    xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true

    # Sign the executable first, then the bundle (Apple's preferred nesting order).
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/MacOS/Stream64"
    if [[ -f "$APP_BUNDLE/Contents/Resources/hvsc-7zz" ]]; then
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$CODESIGN_IDENTITY" \
            "$APP_BUNDLE/Contents/Resources/hvsc-7zz"
    fi
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_app_adhoc() {
    echo "Applying ad-hoc signature (SIGNING=adhoc)..."
    chmod -R u+w "$APP_BUNDLE"
    xattr -cr "$APP_BUNDLE"
    xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
    codesign --force --deep --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

notarize_and_staple_app() {
    require_notarize_credentials
    echo "Submitting app zip for notarization (Apple ID)..."
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    echo "Stapling notarization ticket to app..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
}

notarize_and_staple_dmg() {
    require_notarize_credentials
    # notarytool can hang forever at "Conducting pre-submission checks"
    # when the DMG lives under iCloud Drive (this repo's dist/). Submit a
    # local copy from /tmp, then copy the stapled file back.
    local submit_dmg
    submit_dmg="$(mktemp "${TMPDIR:-/tmp}/stream64-notarize-dmg.XXXXXX").dmg"
    rm -f "$submit_dmg"
    cp -f "$DMG_PATH" "$submit_dmg"
    xattr -cr "$submit_dmg" 2>/dev/null || true
    echo "Submitting DMG for notarization (Apple ID)..."
    xcrun notarytool submit "$submit_dmg" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    echo "Stapling notarization ticket to DMG..."
    xcrun stapler staple "$submit_dmg"
    xcrun stapler validate "$submit_dmg"
    cp -f "$submit_dmg" "$DMG_PATH"
    rm -f "$submit_dmg"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" \
        || true
}

echo "Building $APP_NAME $VERSION ($BUILD_NUMBER) for macOS $ARCH ($SIGNING)..."
swift build --package-path "$ROOT_DIR" -c release --triple "$TRIPLE"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release \
    --triple "$TRIPLE" --show-bin-path)"

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE" "$DMG_ROOT"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH" "$NOTARIZE_ZIP"
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
cp "$BIN_DIR/Stream64_Stream64.bundle/hvsc-7zz" \
    "$APP_BUNDLE/Contents/Resources/hvsc-7zz"
chmod 755 "$APP_BUNDLE/Contents/Resources/hvsc-7zz"
mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses"
cp "$BIN_DIR/Stream64_Stream64.bundle/7-Zip-License.txt" \
    "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/7-Zip-License.txt"
KAOS_ASSETS=(
    kaos-1541.png
    kaos-c64.png
    kaos-cassette.png
    kaos-floppy.png
    kaos-joystick.png
    kaos-monitor.png
    kaos-smiley.png
)
for asset in "${KAOS_ASSETS[@]}"; do
    cp "$BIN_DIR/Stream64_Stream64.bundle/$asset" \
        "$APP_BUNDLE/Contents/Resources/$asset"
    [[ -f "$APP_BUNDLE/Contents/Resources/$asset" ]] || {
        echo "Missing packaged KAOS asset: $asset" >&2
        exit 3
    }
done
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

case "$SIGNING" in
    developer-id)
        sign_app_developer_id
        notarize_and_staple_app
        ;;
    adhoc)
        sign_app_adhoc
        ;;
    *)
        echo "Unsupported SIGNING='$SIGNING' (expected developer-id or adhoc)." >&2
        exit 2
        ;;
esac

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

if [[ "$SIGNING" == "developer-id" ]]; then
    echo "Signing DMG with $CODESIGN_IDENTITY..."
    codesign \
        --force \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
    notarize_and_staple_dmg
else
    codesign --force --sign - "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

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
if [[ "$SIGNING" == "developer-id" ]]; then
    echo "Signed with Developer ID and notarized (stapled)."
else
    echo "This is ad-hoc signed, not notarized. Downloaded copies still require"
    echo "Control-click -> Open (or approval in Privacy & Security) on first launch."
fi
