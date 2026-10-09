#!/bin/bash
# The README's screenshots (docs/screenshots), taken on an iPhone simulator
# by OmakeyUITests/ScreenshotTour, with a clean status bar.
#
#   scripts/screenshots.sh [-d <simulator udid>]
set -euo pipefail
cd "$(dirname "$0")/.."
SIM=""
if [[ ${1:-} == -d ]]; then SIM=$2; shift 2; fi
if [[ -z $SIM ]]; then
  SIM=$(xcrun simctl list devices booted | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}')
fi
xcrun simctl status_bar "$SIM" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode notSupported --batteryState charged --batteryLevel 100
RESULT=".build/screenshots-$(date +%s).xcresult"
status=0
TEST_RUNNER_OMAKEY_SCREENSHOTS=1 xcodebuild -project Omakey.xcodeproj -scheme Omakey -destination "id=$SIM" \
  -derivedDataPath .build/xcode-sim -resultBundlePath "$RESULT" -only-testing:OmakeyUITests/ScreenshotTour test || status=$?
xcrun simctl status_bar "$SIM" clear
[[ $status == 0 ]] || exit $status
OUT=$(mktemp -d)
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null
mkdir -p docs/screenshots
python3 - "$OUT" <<'PY'
import json, subprocess, sys
out = sys.argv[1]
for test in json.load(open(f"{out}/manifest.json")):
    for a in test["attachments"]:
        name = a["suggestedHumanReadableName"].split("_")[0]
        src, dst = f"{out}/{a['exportedFileName']}", f"docs/screenshots/{name}.png"
        props = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", src], capture_output=True, text=True).stdout
        size = {k.strip(): int(v) for k, v in (line.split(":") for line in props.splitlines()[1:] if ":" in line)}
        w, h = size["pixelWidth"], size["pixelHeight"]
        # Landscape screens come out turned a quarter: turned back (checked by eye for this tour).
        landscape = name in ("2-keyboard", "3-touchpad")
        if landscape and h > w:
            subprocess.run(["sips", "-r", "90", src, "--out", src], capture_output=True)
        subprocess.run(["sips", "-Z", "1400" if landscape else "1100", src, "--out", dst], capture_output=True)
        print(dst)
PY
