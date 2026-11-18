#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="build/AppIcon-1024.png"
ICONSET="build/AppIcon.iconset"
APP="build/Backuper.app"

mkdir -p build
swiftc -swift-version 5 Tools/make_icon.swift -o build/make_icon -module-cache-path build/modulecache
./build/make_icon "$MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$MASTER" --out "$ICONSET/icon_$2.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
