#!/bin/bash
# Rebuild GPU runtime assets without regenerating the stock library or CPU kernels.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-build/halide-wasm}"
WEBGPU_HALIDE="${FOTUFILM_WEBGPU_HALIDE:-build/halide-pr-install}"
EMSDK="${EMSDK_ROOT:-build/emsdk}"
python3 tools/webgpu-parity/toolchain.py verify "$WEBGPU_HALIDE"
HOST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
mkdir -p "$OUTPUT" web/public
echo "Building the WebGPU generator… ($WEBGPU_HALIDE)"
env -u SDKROOT clang++ -std=c++17 -O2 \
  ${HOST_SDK:+-isysroot "$HOST_SDK"} \
  -DFOTUFILM_HALIDE_ENABLED=1 \
  -I"$WEBGPU_HALIDE/include" -ISources/FotufilmHalide/include \
  tools/generate_halide_wasm.cpp \
  -L"$WEBGPU_HALIDE/lib" -lHalide -Wl,-rpath,"$WEBGPU_HALIDE/lib" \
  -o "$OUTPUT/generate-webgpu"

echo "Generating WGSL kernels…"
rm -rf "$OUTPUT/webgpu"
"$OUTPUT/generate-webgpu" "$OUTPUT/webgpu" --webgpu

echo "Linking the WebGPU module…"
# JSPI, not Asyncify: the runtime waits on the adapter and on buffer mapping, and JSPI is what
# a current Emscripten instruments those waits with. The export name carries no leading
# underscore here, the opposite of EXPORTED_FUNCTIONS — spell it wrong and the wrapping is
# silently skipped, and the first suspend traps.
em++ -O3 web/engine/fotufilm_wasm.cpp \
  "$OUTPUT"/webgpu/color_float.a "$OUTPUT"/webgpu/monochrome_float.a "$OUTPUT"/webgpu/plain_float.a \
  "$OUTPUT"/webgpu/print_color_float.a "$OUTPUT"/webgpu/print_monochrome_float.a \
  -I Sources/FotufilmHalide/include -I "$OUTPUT/webgpu" \
  --use-port=emdawnwebgpu -sJSPI -sJSPI_EXPORTS=fotufilm_wasm_render \
  -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPF32 \
  -sEXPORTED_FUNCTIONS=_fotufilm_wasm_render,_fotufilm_wasm_control_count,_fotufilm_wasm_control_slot,_fotufilm_wasm_set_slot,_fotufilm_wasm_frame_size_slot,_fotufilm_wasm_set_exposure,_fotufilm_wasm_set_scene,_fotufilm_wasm_set_white_balance,_fotufilm_wasm_set_grain,_fotufilm_wasm_configuration_count,_fotufilm_wasm_lut_count,_fotufilm_wasm_packed_count,_malloc,_free \
  -o web/public/fotufilm-webgpu.mjs
