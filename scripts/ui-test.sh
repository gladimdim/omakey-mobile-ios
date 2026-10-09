#!/bin/bash
# The app and UI tests on an iPhone simulator. The UI tests host the omakeyd
# stand-in in their own process, so nothing types on a real computer.
#
#   scripts/ui-test.sh [-d <simulator udid>] [extra xcodebuild arguments, e.g. -only-testing:OmakeyUITests/KeyboardTour]
#
# A hung test runner (it happens) is stopped after 15 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM=""
if [[ ${1:-} == -d ]]; then SIM=$2; shift 2; fi
if [[ -z $SIM ]]; then
  SIM=$(xcrun simctl list devices booted | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)
fi
if [[ -z $SIM ]]; then
  SIM=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$SIM"
fi
echo "Simulator $SIM"
perl -e 'alarm shift; exec @ARGV' 900 xcodebuild -project Omakey.xcodeproj -scheme Omakey -destination "id=$SIM" \
  -derivedDataPath .build/xcode-sim -resultBundlePath ".build/ui-results-$(date +%s).xcresult" "$@" test
