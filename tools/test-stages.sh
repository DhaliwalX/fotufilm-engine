#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
OUT="build/stage-tests"
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O1 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -I"$HALIDE_PREFIX/include" -ISources/FotufilmHalide -ISources/FotufilmHalide/include \
  tools/test-stages.cpp -L"$HALIDE_PREFIX/lib" -lHalide \
  -Wl,-rpath,"$HALIDE_PREFIX/lib" -o "$OUT/test-stages"
"$OUT/test-stages" cpu
"$OUT/test-stages" metal
