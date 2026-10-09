#!/bin/bash
# A scanned negative's plain reading and trichromatic merge for the browser: one small SIMD module,
# no WebGPU road.
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="${HALIDE_ROOT:-$(tools/resolve-halide-toolchain.sh)}"
source "${EMSDK_ROOT:-build/emsdk}/emsdk_env.sh" >/dev/null 2>&1
OUT=build/negative-wasm
mkdir -p "$OUT" web/public/negative
env -u SDKROOT clang++ -std=c++17 -O2 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$HALIDE/include" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
    tools/generate-negative-wasm.cpp \
    -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/generate"
"$OUT/generate" "$OUT"
em++ -std=c++17 -O3 -msimd128 web/engine/negative_wasm.cpp "$OUT/scan_prepare.a" \
    "$OUT/trichromatic_layer_rgba_kernel.a" "$OUT/trichromatic_layer_rgb16_kernel.a" "$OUT/trichromatic_merge_kernel.a" \
    -I"$OUT" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
    -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB -sMODULARIZE=1 -sEXPORT_ES6=1 \
    -sENVIRONMENT=web,worker -sEXPORTED_RUNTIME_METHODS=HEAPF32,HEAPU8,HEAPU16,HEAP32 \
    -sEXPORTED_FUNCTIONS=_scan_prepare_plain,_fotufilm_trichromatic_measure,_trichromatic_measure_rgb16,_fotufilm_trichromatic_group,_fotufilm_trichromatic_layer,_trichromatic_layer_rgb16,_fotufilm_trichromatic_register,_fotufilm_trichromatic_repeats,_fotufilm_trichromatic_file_size,_fotufilm_trichromatic_merge,_malloc,_free \
    -o web/public/negative/prepare.mjs
