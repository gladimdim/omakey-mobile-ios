#!/bin/bash
# An Instruments trace of the app on a connected iPhone, then the app opened
# again in stay-awake mode, so the phone doesn't lock before the next run.
#
#   scripts/perf-trace.sh <template> <output.trace> [seconds] [-d <device udid>]
#   e.g. scripts/perf-trace.sh 'App Launch' /tmp/launch.trace 6
set -euo pipefail
TEMPLATE=$1; OUT=$2; SECS=${3:-6}
DEV=""
if [[ ${4:-} == -d ]]; then DEV=$5; fi
if [[ -z $DEV ]]; then
  DEV=$(xcrun devicectl list devices 2>/dev/null | grep connected | grep physical | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{16}' || true)
fi
rm -rf "$OUT"
status=0
xcrun xctrace record --template "$TEMPLATE" --device "$DEV" --time-limit "${SECS}s" --output "$OUT" \
  --env OMAKEY_STAY_AWAKE=1 --launch -- com.gladimdim.omakey || status=$?
xcrun devicectl device process launch --device "$DEV" --terminate-existing -e '{"OMAKEY_STAY_AWAKE":"1"}' com.gladimdim.omakey >/dev/null 2>&1 || true
exit $status
