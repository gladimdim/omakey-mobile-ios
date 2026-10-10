#!/bin/bash
# The README's screenshots (docs/screenshots), taken on an iPhone simulator
# by OmakeyUITests/ScreenshotTour, with a clean status bar.
#
#   scripts/screenshots.sh [-d <simulator udid>]
#   scripts/screenshots.sh --from <.xcresult>    # only redo the pictures from a run
set -euo pipefail
cd "$(dirname "$0")/.."
SIM=""
RESULT=""
if [[ ${1:-} == -d ]]; then SIM=$2; shift 2; fi
if [[ ${1:-} == --from ]]; then RESULT=$2; shift 2; fi
if [[ -z $RESULT ]]; then
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
fi
OUT=$(mktemp -d)
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null
rm -rf docs/screenshots
mkdir -p docs/screenshots
python3 - "$OUT" <<'PY'
import json, subprocess, sys
out = sys.argv[1]
def size(path):
    props = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    s = {k.strip(): int(v) for k, v in (line.split(":") for line in props.splitlines()[1:] if ":" in line)}
    return s["pixelWidth"], s["pixelHeight"]
for test in json.load(open(f"{out}/manifest.json")):
    for a in test["attachments"]:
        # "omakey-pro.landscape_0_<uuid>.png": the name, before XCTest's counter.
        name = a["suggestedHumanReadableName"].split("_")[0]
        landscape = name.endswith(".landscape")
        name = name.removesuffix(".landscape")
        src, dst = f"{out}/{a['exportedFileName']}", f"docs/screenshots/{name}.png"
        w, h = size(src)
        # A sideways screen comes out as an upright picture turned a quarter: turned back.
        if landscape and h > w:
            subprocess.run(["sips", "-r", "90", src, "--out", src], capture_output=True)
        longest = 1400 if name in ("omakey-pro", "touchpad") else 1000 if landscape else 1100
        subprocess.run(["sips", "-Z", str(longest), src, "--out", dst], capture_output=True)
        print(dst, f"(taken {w}x{h})")
PY
swift scripts/round-corners.swift docs/screenshots/*.png
