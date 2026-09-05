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
xcrun clang++ -std=c++17 -O2 -DFOTUFILM_HALIDE_IOS_AOT=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  tools/aot-window-tests.cpp Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  "$KERNELS"/*.a -framework Metal -framework Foundation -o "$OUT/runner"
for mode in 0 1; do
  FOTUFILM_AOT_WINDOWED="$mode" "$OUT/runner" "$1" "$OUT/$mode"
done
python3 - "$OUT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
general = sorted((root / "0").glob("*.f32"))
windowed = sorted((root / "1").glob("*.f32"))
assert len(general) == len(windowed) == 18, "missing comparison frames"
for left, right in zip(general, windowed):
    assert left.name == right.name
    assert left.read_bytes() == right.read_bytes(), f"output differs: {left.name}"
print("PASS: all 18 general/windowed AOT frames match byte for byte")
PY
