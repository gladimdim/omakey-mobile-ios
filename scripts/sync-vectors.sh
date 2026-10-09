#!/bin/bash
# Copy the protocol test vectors from the daemon repo. They must keep
# passing byte for byte (OmakeyKit/Tests/OmakeyProtocolTests).
#   scripts/sync-vectors.sh [path/to/omakey-omarchy-plugin]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/../omakey-omarchy-plugin}/docs/test-vectors.json"
[[ -f $SRC ]] || { echo "no test vectors at $SRC" >&2; exit 1; }
cp "$SRC" "$ROOT/OmakeyKit/Tests/OmakeyProtocolTests/Fixtures/test-vectors.json"
echo "Synced $SRC"
