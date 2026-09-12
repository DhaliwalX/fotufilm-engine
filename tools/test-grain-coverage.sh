#!/bin/bash
# Check the original seeded disc unions on the host CPU and Metal.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
OUT="build/grain-coverage"
mkdir -p "$OUT"
xcrun clang++ -std=c++17 -O2 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -I"$HALIDE_PREFIX/include" -ISources/FotufilmHalide -ISources/FotufilmHalide/include \
  tools/test-grain-coverage.cpp -L"$HALIDE_PREFIX/lib" -lHalide \
  -Wl,-rpath,"$HALIDE_PREFIX/lib" -o "$OUT/test-grain-coverage"
"$OUT/test-grain-coverage" cpu
"$OUT/test-grain-coverage" metal
