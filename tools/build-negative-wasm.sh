#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HALIDE="${FOTUFILM_WEBGPU_HALIDE:-build/halide-pr-install}"
MODES=(cpu gpu)
if [[ -f "$HALIDE/include/Halide.h" ]]; then
    python3 tools/webgpu-parity/toolchain.py verify "$HALIDE"
else
    HALIDE="${HALIDE_ROOT:-$(tools/resolve-halide-toolchain.sh)}"
    MODES=(cpu)
    rm -f web/public/negative/gpu.mjs web/public/negative/gpu.wasm
    echo "WebGPU Halide unavailable; building the negative converter's SIMD fallback."
fi
source "${EMSDK_ROOT:-build/emsdk}/emsdk_env.sh" >/dev/null 2>&1
OUT=build/negative-wasm
mkdir -p "$OUT/cpu" "$OUT/gpu" web/public/negative
clang++ -std=c++17 -O2 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$HALIDE/include" -ISources/FotufilmHalide/include tools/generate-negative-wasm.cpp \
    -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -o "$OUT/generate"
for mode in "${MODES[@]}"; do
    "$OUT/generate" "$OUT/$mode/negative_scan" "$mode"
    EXTRA=(-sALLOW_MEMORY_GROWTH=1)
    if [[ "$mode" == gpu ]]; then
        EXTRA=(-sALLOW_MEMORY_GROWTH=1 --use-port=emdawnwebgpu -sJSPI -sJSPI_EXPORTS=negative_convert)
    fi
    em++ -O3 -msimd128 web/engine/negative_wasm.cpp "$OUT/$mode/negative_scan.a" \
        -I"$OUT/$mode" "${EXTRA[@]}" \
        -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
        -sEXPORTED_RUNTIME_METHODS=HEAPF32 -sEXPORTED_FUNCTIONS=_negative_convert,_malloc,_free \
        -o "web/public/negative/$mode.mjs"
done
