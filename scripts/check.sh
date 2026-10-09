#!/bin/bash
# Package tests on the Mac, then an unsigned build of the app for devices.
#   scripts/check.sh [extra xcodebuild settings…]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/package-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --package-path OmakeyKit --disable-sandbox --cache-path .build/package-cache \
  --scratch-path .build/package -Xswiftc -module-cache-path -Xswiftc .build/module-cache
xcodebuild -project Omakey.xcodeproj -scheme Omakey -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO "$@" build
