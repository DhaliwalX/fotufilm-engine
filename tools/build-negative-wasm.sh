#!/bin/bash
# A scanned negative's plain reading for the browser: one small SIMD module, no WebGPU road.
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="${HALIDE_ROOT:-$(tools/resolve-halide-toolchain.sh)}"
source "${EMSDK_ROOT:-build/emsdk}/emsdk_env.sh" >/dev/null 2>&1
OUT=build/negative-wasm
mkdir -p "$OUT" web/public/negative
env -u SDKROOT clang++ -std=c++17 -O2 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$HALIDE/include" -ISources/FotufilmHalide/include tools/generate-negative-wasm.cpp \
    -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/generate"
"$OUT/generate" "$OUT"
em++ -O3 -msimd128 web/engine/negative_wasm.cpp "$OUT/scan_prepare.a" -I"$OUT" \
    -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
    -sEXPORTED_RUNTIME_METHODS=HEAPF32 \
    -sEXPORTED_FUNCTIONS=_scan_prepare_plain,_malloc,_free \
    -o web/public/negative/prepare.mjs
