#!/bin/bash
# The photo library's thumbnail resampler: one small SIMD module, no WebGPU road.
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="${HALIDE_ROOT:-$(tools/resolve-halide-toolchain.sh)}"
source "${EMSDK_ROOT:-build/emsdk}/emsdk_env.sh" >/dev/null 2>&1
OUT=build/library-wasm
mkdir -p "$OUT" web/public/library
env -u SDKROOT clang++ -std=c++17 -O2 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$HALIDE/include" tools/generate-library-wasm.cpp \
    -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/generate"
"$OUT/generate" "$OUT/library_thumbnail"
em++ -O3 -msimd128 web/engine/library_wasm.cpp "$OUT/library_thumbnail.a" -I"$OUT" \
    -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
    -sEXPORTED_RUNTIME_METHODS=HEAPU8 \
    -sEXPORTED_FUNCTIONS=_library_thumbnail_rgba,_malloc,_free \
    -o web/public/library/thumbnail.mjs
