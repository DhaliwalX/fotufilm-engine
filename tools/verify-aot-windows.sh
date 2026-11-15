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
  rm -f "${OUT:?}/${mode:?}/"*.f32
  FOTUFILM_AOT_WINDOWED="$mode" FOTUFILM_TRACE_VARIANT=1 \
    "$OUT/runner" "$1" "$OUT/$mode" 2> "$OUT/$mode.trace"
  cat "$OUT/$mode.trace"
done
# Once more with the windows on and every request kept on its gated twin, to hold the twins
# compiled for exactly one stage set against the gated twins they stand in for.
mkdir -p "$OUT/gated"
rm -f "${OUT:?}/gated/"*.f32
FOTUFILM_AOT_WINDOWED=1 FOTUFILM_AOT_EXACT=0 FOTUFILM_TRACE_VARIANT=1 \
  "$OUT/runner" "$1" "$OUT/gated" 2> "$OUT/gated.trace"
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
gated = sorted((root / "gated").glob("*.f32"))
assert len(general) == len(windowed) == len(gated) == 82, "missing comparison frames"
assert "for exactly its stages" in (root / "1.trace").read_text(), \
    "no twin compiled for exactly its stages was exercised"
assert "for exactly its stages" not in (root / "gated.trace").read_text(), \
    "FOTUFILM_AOT_EXACT=0 did not keep requests on their gated twins"
# A twin compiled for exactly its stages stands in for the gated twin, so it is held to it
# directly, at the tolerance the windowed and general variants are held to below. A
# `gated_parity` twin ("parity-") keeps the scalar selects that make Metal contract the gated
# graph's expressions; where that reaches the bit, the count below says so.
def linear(name):
    if 'rec709' in name:
        return lambda v: math.copysign(abs(v) ** 2.4, v)
    if 'srgb' in name:
        return lambda v: math.copysign(abs(v) / 12.92 if abs(v) <= 0.04045
                                       else ((abs(v) + 0.055) / 1.055) ** 2.4, v)
    return lambda v: v
twins = identical = 0
twin_worst = 0.0
for left, right in zip(windowed, gated):
    assert left.name == right.name
    if not left.name.startswith(("parity-", "exact-")):
        assert left.read_bytes() == right.read_bytes(), \
            f"FOTUFILM_AOT_EXACT=0 changed a frame no exact twin serves: {left.name}"
        continue
    a, b = array('f'), array('f')
    a.frombytes(left.read_bytes())
    b.frombytes(right.read_bytes())
    assert len(a) == len(b), f"frame size differs: {left.name}"
    decode = linear(left.name)
    error = max(abs(decode(x) - decode(y)) for x, y in zip(a, b))
    assert error <= 1e-5, f"exact twin differs from its gated twin: {left.name}, error {error}"
    twins += 1
    identical += a == b
    twin_worst = max(twin_worst, error)
assert twins == 10, "missing exact-twin comparison frames"
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
    # below one 16-bit code; a corrupt window read differs by up to full scale.
    assert error <= 1e-5, f"output differs: {left.name}, maximum error {error}"
    assert encoded_error < 1 / 255, f"encoded output differs: {left.name}, error {encoded_error}"
    worst = max(worst, error)
print(f"PASS: all {len(general)} general/windowed AOT frames agree; maximum linear error {worst:.3g}")
print(f"PASS: all {twins} exact-twin frames agree with their gated twins, {identical} of them "
      f"bit for bit; maximum linear error {twin_worst:.3g}")
PY
