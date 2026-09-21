#!/bin/bash
# Link a probe with no preset dispatch cases to exercise every runtime-gated fallback.
set -euo pipefail
cd "$(dirname "$0")/.."
CPU="${1:-build/halide-wasm/cpu}"
PROBE="${CPU%/cpu}/flexible-test"
EMSDK="${EMSDK_ROOT:-build/emsdk}"
mkdir -p "$PROBE" web/public/test
[[ -f "$CPU/develop_flexible.a" ]] || { echo 'Run tools/build-wasm.sh first.' >&2; exit 1; }
# The first preset header owns the generated Halide ABI declarations. Keep
# those headers even though the empty dispatch table forces every fallback.
if [[ -f "$CPU/fotufilm_wasm_variants.h" ]]; then
  cp "$CPU/fotufilm_wasm_variants.h" "$PROBE/fotufilm_wasm_variants.h"
else
  # A flexible-only generation embeds its ABI in develop_flexible.h instead.
  : > "$PROBE/fotufilm_wasm_variants.h"
fi
: > "$PROBE/fotufilm_wasm_variants.inc"
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
em++ -std=c++17 -O1 web/engine/fotufilm_wasm_cpu.cpp \
  "$CPU"/develop_*.a "$CPU"/print_*.a "$CPU"/plain_float.a \
  -I Sources/FotufilmHalide/include -I "$PROBE" -I "$CPU" \
  -msimd128 -sALLOW_MEMORY_GROWTH=1 \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPF32 \
  -sEXPORTED_FUNCTIONS=_fotufilm_wasm_transport,_fotufilm_wasm_control_count,_fotufilm_wasm_control_slot,_fotufilm_wasm_set_slot,_fotufilm_wasm_cpu_render,_fotufilm_wasm_frame_size_slot,_fotufilm_wasm_set_exposure,_fotufilm_wasm_set_scene,_fotufilm_wasm_set_white_balance,_fotufilm_wasm_set_grain,_fotufilm_wasm_configuration_count,_fotufilm_wasm_lut_count,_malloc,_free \
  -o web/public/test/flexible.mjs
