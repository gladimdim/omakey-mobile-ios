#!/bin/bash
# Copy the layout spec files the app bundles: keycodes.json and the stock
# layouts. From the layout studio when it's checked out next to this repo,
# else from the Android app's copy of the same files.
#
#   scripts/sync-spec.sh [path/to/omakey-layout-studio/spec | path/to/android/assets]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/OmakeyKit/Sources/OmakeyCore/Spec"
if [[ $# -gt 0 ]]; then
  SRC="$1"
elif [[ -f $ROOT/../omakey-layout-studio/spec/keycodes.json ]]; then
  SRC="$ROOT/../omakey-layout-studio/spec"
else
  SRC="$ROOT/../omakey-mobile/android/app/src/main/assets"
fi
[[ -f $SRC/keycodes.json ]] || { echo "no spec at $SRC" >&2; exit 1; }
mkdir -p "$DEST/layouts"
cp "$SRC/keycodes.json" "$DEST/keycodes.json"
# Mirror, don't merge: a stock layout removed or renamed upstream must not
# linger in the app as a built-in.
for f in "$DEST"/layouts/*.json; do
  [[ -e $f && ! -e $SRC/layouts/$(basename "$f") ]] && { rm "$f"; echo "Removed stale $(basename "$f")"; }
done
cp "$SRC"/layouts/*.json "$DEST/layouts/"
echo "Synced $(ls "$SRC"/layouts/*.json | wc -l | tr -d ' ') layout(s) and keycodes.json from $SRC"
