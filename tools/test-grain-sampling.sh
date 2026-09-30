#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="$(bash tools/resolve-halide-toolchain.sh)"
OUT=build/grain-sampling
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O2 -ffp-contract=off -I"$HALIDE/include" \
    -ISources/FotufilmHalide -ISources/FotufilmHalide/include \
    tools/test-grain-sampling.cpp -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/check"
"$OUT/check"
