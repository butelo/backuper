#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Backuper"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
MODULE_CACHE="$BUILD_DIR/modulecache"
MIN_MACOS="13.0"

mkdir -p "$BUILD_DIR"

if [ ! -f "Resources/AppIcon.icns" ]; then
    ./Tools/make_icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile_arch() {
    local arch="$1"
    local out="$BUILD_DIR/$APP_NAME-$arch"
    mkdir -p "$MODULE_CACHE/$arch"
    echo "Compiling ${arch}"
    swiftc -O -swift-version 5 \
        -target "$arch-apple-macos$MIN_MACOS" \
        -module-cache-path "$MODULE_CACHE/$arch" \
        -sdk "$SDK" \
        Sources/*.swift \
        -o "$out"
}

compile_arch arm64
compile_arch x86_64

echo "Creating universal binary…"
lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" \
     -output "$APP/Contents/MacOS/$APP_NAME"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"
chmod 644 "$APP/Contents/Info.plist" "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/PkgInfo"

echo "Signing (ad-hoc)…"
codesign --force --sign - --identifier com.backuper.app "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"

echo
echo "Built $APP"
echo "Zip:  $BUILD_DIR/$APP_NAME.zip"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
