#!/bin/bash
# Exercise the actual Android generator and adapter on the host, without a device or emulator.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/android-parity
HALIDE="$(bash tools/resolve-halide-toolchain.sh)"
mkdir -p "$OUT"
CXX="${CXX:-clang++}"
COMMON=(-std=c++17 -O2 -I"$HALIDE/include" -ISources/FotufilmHalide/include)
LINK=(-L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib")
"$CXX" "${COMMON[@]}" tools/generate_halide_android.cpp "${LINK[@]}" -o "$OUT/generate"
"$OUT/generate" "$OUT/kernels" --host
if [[ -n "${FOTUFILM_PARITY_CLI:-}" ]]; then
  CLI=("$FOTUFILM_PARITY_CLI")
else
  CLI=(swift run -c release fotufilm)
fi
FOTUFILM_STOCKS="$PWD/Sources/FotufilmCore/Stocks" "${CLI[@]}" \
  --dump-wasm-pack "$OUT/example.fswp" --stock example-negative-400 --pack-size 96x64
"$CXX" "${COMMON[@]}" -DFOTUFILM_HALIDE_ANDROID_AOT=1 -I"$OUT/kernels" \
  tools/android-aot-parity.cpp Sources/FotufilmHalide/FotufilmHalideAndroid.cpp \
  "$OUT/kernels"/*.a -o "$OUT/aot"
"$CXX" "${COMMON[@]}" -DFOTUFILM_HALIDE_ENABLED=1 \
  tools/android-aot-parity.cpp Sources/FotufilmHalide/FotufilmHalide.cpp \
  "${LINK[@]}" -o "$OUT/jit"
"$OUT/aot" "$OUT/example.fswp" > "$OUT/aot.bin"
"$OUT/jit" "$OUT/example.fswp" > "$OUT/jit.bin"
python3 - <<'PY'
from array import array
from pathlib import Path
from math import isfinite
n = 96 * 64 * 3
outputs = []
for name in ('aot', 'jit'):
    values = array('f')
    values.frombytes(Path(f'build/android-parity/{name}.bin').read_bytes())
    assert len(values) == n * 32, (name, len(values))
    assert all(map(isfinite, values)), name
    outputs.append(values)
for case in range(32):
    error = max(abs(a-b) for a,b in zip(*(v[case*n:(case+1)*n] for v in outputs)))
    assert error < 1e-4, (case, error)
for name, values in zip(('aot','jit'), outputs):
    for variant in range(4):
        start = variant * 8 * n
        for stage in (1,2,3):
            effect = max(abs(values[start+i]-values[start+stage*n+i]) for i in range(n))
            assert effect > 1e-5, (name, variant, stage, effect)
print('Android AOT / CPU reference: 32 cases pass; diffusion, mottle and print MTF affect all four print variants.')
PY
