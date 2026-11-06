#!/bin/bash
# SCRATCH (branch inspector-crash, never merged): the Mac's screens taken
# twice from one build, with and without the caret held, and compared.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
apps="$1"; out="$2"
mkdir -p "$out"
for variant in held-1 held-2 plain-1 plain-2; do
    case "$variant" in
        held-*) export PROOF_MAC_EXTRA_ARGS="-NSTextInsertionPointBlinkPeriodOn 100000000 -NSTextInsertionPointBlinkPeriodOff 0.001" ;;
        *) export PROOF_MAC_EXTRA_ARGS="" ;;
    esac
    tools/ci/proof_mac.sh "$apps" "$out/$variant" > "$out/$variant.log" 2>&1 || echo "$variant failed"
done
python3 -I - "$ROOT/tools/isomer/snapshots" "$out" << 'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import pngdiff
out = sys.argv[2]
for a, b in (("held-1", "held-2"), ("plain-1", "plain-2")):
    for name in sorted(os.listdir(os.path.join(out, a, "screens"))):
        x, y = os.path.join(out, a, "screens", name), os.path.join(out, b, "screens", name)
        if os.path.exists(y):
            print(a, "vs", b, name, pngdiff.compare(x, y, os.path.join(out, f"diff-{a}-{name}")))
PY
