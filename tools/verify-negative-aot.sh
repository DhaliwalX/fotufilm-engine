#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KERNELS="${1:-build/halide-macos}"
OUT=build/negative-aot-parity
HALIDE="$(tools/resolve-halide-toolchain.sh)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O2 -isysroot "$SDK" -target arm64-apple-macos14.0 \
  -DFOTUFILM_HALIDE_IOS_AOT=1 -I"$KERNELS" -ISources/FotufilmHalide/include \
  tools/negative-aot-parity.cpp Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  "$KERNELS"/*.a -framework Metal -framework Foundation -o "$OUT/aot"
xcrun clang++ -std=c++17 -O2 -isysroot "$SDK" -target arm64-apple-macos14.0 \
  -DFOTUFILM_HALIDE_ENABLED=1 -I"$HALIDE/include" -ISources/FotufilmHalide/include \
  tools/negative-aot-parity.cpp Sources/FotufilmHalide/FotufilmNegativeScan.cpp \
  -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -framework Metal -o "$OUT/jit"
"$OUT/aot" > "$OUT/aot.bin"
"$OUT/jit" > "$OUT/jit.bin"
python3 - <<'PY'
from array import array
from pathlib import Path
outputs=[]
for name in ['aot','jit']:
    values=array('f');values.frombytes(Path(f'build/negative-aot-parity/{name}.bin').read_bytes())
    assert len(values)==513*19*3*4
    outputs.append(values)
error=max(abs(a-b) for a,b in zip(*outputs))
assert error < 2e-5, error
print(f'Automatic negative AOT/JIT CPU+Metal: max error {error:g}')
PY
