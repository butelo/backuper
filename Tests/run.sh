#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
mkdir -p build
echo "Compiling tests for ${ARCH}"
swiftc -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -module-cache-path "build/modulecache/tests" \
    Sources/Models.swift \
    Sources/Storage.swift \
    Sources/Format.swift \
    Sources/Xattr.swift \
    Sources/Catalog.swift \
    Sources/CloudFolderLocator.swift \
    Sources/SyncEngine.swift \
    Sources/RestoreEngine.swift \
    Tests/main.swift \
    -o build/BackuperTests

./build/BackuperTests
