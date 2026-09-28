#!/usr/bin/env bash
# Generates the Linux AOT kernels: the frame variants for CUDA and for Vulkan, side by side, and
# the one Halide runtime both share. Needs a Halide SDK with both backends (HALIDE_ROOT) and the
# Vulkan patches in tools/ (tools/vulkan-parity/README.md).
#   tools/generate-halide-aot-linux.sh [output-dir]      default build/halide-linux-x86_64
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
HALIDE="${HALIDE_ROOT:?set HALIDE_ROOT to a Halide SDK with CUDA and Vulkan}"
OUTPUT="${1:-build/halide-linux-x86_64}"
JOBS="${FOTUFILM_AOT_JOBS:-$(nproc)}"
mkdir -p "$OUTPUT"
GENERATOR="$OUTPUT/generate-halide-aot"

echo "Building the Halide generator…"
"${CXX:-clang++}" -std=c++17 -O2 -I"$HALIDE/include" -ISources/FotufilmHalide/include \
  tools/generate_halide_ios.cpp -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -lpthread -ldl \
  -o "$GENERATOR"

VARIANTS="$("$GENERATOR" "$OUTPUT" --count)"
for device in cuda vulkan; do
  echo "Generating $device kernels: $VARIANTS variants, $JOBS at a time…"
  seq 0 $((VARIANTS - 1)) | xargs -P "$JOBS" -I{} \
    "$GENERATOR" "$OUTPUT" "--linux-$device" "--prefix=fotufilm_aot_${device}_" "--variant={}"
done
"$GENERATOR" "$OUTPUT" --linux-cuda --prefix=fotufilm_aot_ --extras
cp "$HALIDE/include/HalideBuffer.h" "$HALIDE/include/HalideRuntime.h" \
   "$HALIDE/include/HalideRuntimeCuda.h" "$HALIDE/include/HalideRuntimeVulkan.h" "$OUTPUT/"
echo "Wrote Linux kernels to $OUTPUT"
