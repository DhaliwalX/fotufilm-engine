#!/bin/bash
# Compare windowed and general AOT output, using an exported public stock fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# != 1 )); then
  echo "usage: tools/verify-aot-windows.sh fixture.fswp" >&2
  exit 2
fi
KERNELS="${FOTUFILM_PARITY_KERNELS:-build/halide-macos}"
OUT="build/aot-window-tests"
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O2 -DFOTUFILM_HALIDE_IOS_AOT=1 -DFOTUFILM_AOT_WINDOWED_HOST=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  tools/aot-window-tests.cpp Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  "$KERNELS"/*.a -framework Metal -framework Foundation -o "$OUT/runner"
for mode in 0 1; do
  FOTUFILM_AOT_WINDOWED="$mode" FOTUFILM_TRACE_VARIANT=1 \
    "$OUT/runner" "$1" "$OUT/$mode" 2> "$OUT/$mode.trace"
  cat "$OUT/$mode.trace"
done
python3 - "$OUT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
assert "Fotufilm AOT:" not in (root / "0.trace").read_text(), "general path used windows"
assert "Fotufilm AOT:" in (root / "1.trace").read_text(), "windowed path was not exercised"
general = sorted((root / "0").glob("*.f32"))
windowed = sorted((root / "1").glob("*.f32"))
assert len(general) == len(windowed) == 22, "missing comparison frames"
for left, right in zip(general, windowed):
    assert left.name == right.name
    assert left.read_bytes() == right.read_bytes(), f"output differs: {left.name}"
print("PASS: all 22 general/windowed AOT frames match byte for byte")
PY
