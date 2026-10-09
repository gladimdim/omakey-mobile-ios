#!/bin/bash
# How fast the app is on a connected iPhone (Release build): start-up, the
# keyboard and the pages coming up, scrolling, typing and the touchpad, on
# the demo computer inside the app (OmakeyUITests/PerformanceTour).
#
#   scripts/perf-test.sh [-d <device udid>] [extra xcodebuild arguments, e.g. -only-testing:OmakeyUITests/PerformanceTour/testTyping]
#
# Safe on your own phone: no reset, nothing picked or changed. The phone must
# be unlocked to start; the app keeps it awake while the tests run, and is
# left open afterwards (OMAKEY_STAY_AWAKE) so it stays awake between runs.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=""
if [[ ${1:-} == -d ]]; then DEV=$2; shift 2; fi
if [[ -z $DEV ]]; then
  DEV=$(xcrun devicectl list devices 2>/dev/null | grep connected | grep physical | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{16}' || true)
fi
[[ -n $DEV ]] || { echo "No iPhone connected" >&2; exit 1; }
echo "iPhone $DEV"
ONLY=(-only-testing:OmakeyUITests/PerformanceTour)
for a in "$@"; do [[ $a == -only-testing:* ]] && ONLY=(); done
status=0
TEST_RUNNER_OMAKEY_PERF=1 perl -e 'alarm shift; exec @ARGV' 1800 xcodebuild -project Omakey.xcodeproj -scheme "Omakey Performance" \
  -destination "id=$DEV" -derivedDataPath .build/xcode-device -allowProvisioningUpdates \
  -resultBundlePath ".build/perf-$(date +%s).xcresult" ${ONLY[@]+"${ONLY[@]}"} "$@" test || status=$?
# Keep the phone awake until the next run.
xcrun devicectl device process launch --device "$DEV" --terminate-existing -e '{"OMAKEY_STAY_AWAKE":"1"}' com.gladimdim.omakey >/dev/null 2>&1 || true
exit $status
