#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-0.1.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
APP_NAME="LuckySQL"
ARCHIVE_NAME="${APP_NAME}-v${VERSION}-macos-arm64.zip"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

if [[ -n "${LUCKYSQL_BINARY:-}" ]]; then
    BINARY_PATH="$LUCKYSQL_BINARY"
else
    swift build --package-path "$REPO_ROOT" -c release --arch arm64
    BINARY_PATH="$(swift build --package-path "$REPO_ROOT" -c release --arch arm64 --show-bin-path)/$APP_NAME"
fi

if [[ ! -x "$BINARY_PATH" ]]; then
    echo "LuckySQL executable not found at: $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
rm -f "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME.sha256"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

install -m 755 "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
install -m 644 "$REPO_ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
ditto "$REPO_ROOT/Resources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/zh-Hans.lproj"

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleDevelopmentRegion -string en "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string com.cookzhang.LuckySQL "$INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$VERSION" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"

# No Developer ID certificate is required for local builds. The ad-hoc signature
# keeps the bundle internally consistent while making its unsigned status clear.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

(
    cd "$DIST_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ARCHIVE_NAME"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "Created $DIST_DIR/$ARCHIVE_NAME"
echo "Created $DIST_DIR/$ARCHIVE_NAME.sha256"
