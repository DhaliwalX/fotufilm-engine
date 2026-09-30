#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="$(bash tools/resolve-halide-toolchain.sh)"
OUT=build/portable-grain
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O1 -I"$HALIDE/include" \
    -ISources/FotufilmHalide -ISources/FotufilmHalide/include \
    tools/test-portable-grain.cpp -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/check"
"$OUT/check" "$OUT"
