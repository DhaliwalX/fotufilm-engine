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
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang++ -std=c++17 -O2 -DFOTUFILM_HALIDE_IOS_AOT=1 -DFOTUFILM_AOT_WINDOWED_HOST=1 \
  -isysroot "$SDK" -target "$(uname -m)-apple-macos14.0" \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  tools/aot-window-tests.cpp Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  "$KERNELS"/*.a -framework Metal -framework Foundation -o "$OUT/runner"
for mode in 0 1; do
  mkdir -p "$OUT/$mode"
  rm -f "$OUT/$mode/"*.f32
  FOTUFILM_AOT_WINDOWED="$mode" FOTUFILM_TRACE_VARIANT=1 \
    "$OUT/runner" "$1" "$OUT/$mode" 2> "$OUT/$mode.trace"
  cat "$OUT/$mode.trace"
done
python3 - "$OUT" <<'PY'
from pathlib import Path
from array import array
import math
import sys

root = Path(sys.argv[1])
assert "Fotufilm AOT:" not in (root / "0.trace").read_text(), "general path used windows"
assert "Fotufilm AOT:" in (root / "1.trace").read_text(), "windowed path was not exercised"
general = sorted((root / "0").glob("*.f32"))
windowed = sorted((root / "1").glob("*.f32"))
assert len(general) == len(windowed) == 40, "missing comparison frames"
worst = 0.0
for left, right in zip(general, windowed):
    assert left.name == right.name
    a, b = array('f'), array('f')
    a.frombytes(left.read_bytes())
    b.frombytes(right.read_bytes())
    assert len(a) == len(b), f"frame size differs: {left.name}"
    assert all(math.isfinite(v) for v in a) and all(math.isfinite(v) for v in b)
    encoded_error = max(abs(x - y) for x, y in zip(a, b))
    # Gamma 2.4 magnifies opposite-signed roundoff at fitted black (about
    # +/-4e-8 linear) into roughly 0.0015 encoded. Compare the underlying light
    # and also bound the delivered difference to less than one 8-bit code.
    if 'rec709' in left.name:
        decode = lambda v: math.copysign(abs(v) ** 2.4, v)
    elif 'srgb' in left.name:
        decode = lambda v: math.copysign(abs(v) / 12.92 if abs(v) <= 0.04045
                                        else ((abs(v) + 0.055) / 1.055) ** 2.4, v)
    else:
        decode = lambda v: v
    error = max(abs(decode(x) - decode(y)) for x, y in zip(a, b))
    # Independently compiled Metal schedules can round the same expression
    # differently (previous kernels differ by up to 2.7e-6). Keep the allowance
    # below one 16-bit code; a corrupt folded read differs by up to full scale.
    assert error <= 1e-5, f"output differs: {left.name}, maximum error {error}"
    assert encoded_error < 1 / 255, f"encoded output differs: {left.name}, error {encoded_error}"
    worst = max(worst, error)
print(f"PASS: all 40 general/windowed AOT frames agree; maximum linear error {worst:.3g}")
PY
