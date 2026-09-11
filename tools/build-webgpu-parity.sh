#!/bin/bash
# Build development-only CPU and WebGPU math probes. No image rendering fallback.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-build/webgpu-parity/math}"
CPU_HALIDE="${HALIDE_ROOT:-build/halide-install}"
GPU_HALIDE="${FOTUFILM_WEBGPU_HALIDE:-build/halide-pr-install}"
TASK_EMSDK="${EMSDK_ROOT:-build/emsdk}"
for prefix in "$CPU_HALIDE" "$GPU_HALIDE"; do
  [[ -f "$prefix/include/Halide.h" ]] || {
    echo "Missing Halide headers: set HALIDE_ROOT and FOTUFILM_WEBGPU_HALIDE." >&2
    exit 1
  }
done
python3 tools/webgpu-parity/toolchain.py verify "$GPU_HALIDE"
[[ -f "$TASK_EMSDK/emsdk_env.sh" ]] || {
  echo "Missing Emscripten: set EMSDK_ROOT." >&2
  exit 1
}
source "$TASK_EMSDK/emsdk_env.sh" >/dev/null 2>&1
mkdir -p "$OUTPUT" web/public/parity
TASK_HOST_FLAGS=(-fPIC)
if [[ "$(uname -s)" == Darwin ]]; then
  TASK_HOST_FLAGS+=(-isysroot "$(xcrun --sdk macosx --show-sdk-path)")
fi
for mode in cpu gpu; do
  if [[ "$mode" == cpu ]]; then prefix="$CPU_HALIDE"; else prefix="$GPU_HALIDE"; fi
  # Use absolute rpaths so generators also work with the default relative prefixes.
  prefix="$(cd "$prefix" && pwd)"
  "${CXX:-c++}" -std=c++17 -O2 "${TASK_HOST_FLAGS[@]}" \
    -I"$prefix/include" -ISources/FotufilmHalide -ISources/FotufilmHalide/include \
    tools/webgpu-parity/generate.cpp -L"$prefix/lib" -lHalide \
    -Wl,-rpath,"$prefix/lib" -o "$OUTPUT/generate-$mode"
  "$OUTPUT/generate-$mode" "$OUTPUT/$mode" "$mode"
  options=(-msimd128)
  if [[ "$mode" == gpu ]]; then
    options+=(--use-port=emdawnwebgpu -sJSPI -sJSPI_EXPORTS=run_math)
  fi
  em++ -O3 tools/webgpu-parity/entry.cpp "$OUTPUT/$mode/parity_math.a" \
    -I"$OUTPUT/$mode" "${options[@]}" \
    -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
    -sEXPORTED_FUNCTIONS=_run_math,_malloc,_free \
    -sEXPORTED_RUNTIME_METHODS=ccall,HEAPF32 \
    -o "web/public/parity/math-$mode.mjs"
done
cp tools/webgpu-parity/reference-math.wgsl web/public/parity/softfloat.wgsl
cp tools/webgpu-parity/HALIDE-LICENSE.txt web/public/parity/
echo "Built probes. Run npm run dev in web and open /test/parity-math.html."
