#!/usr/bin/env bash
# Generates the Android AOT kernels: the frame variants for Vulkan, and the one Halide runtime they
# share with the CPU extras, for arm64. The phone develops through the Linux shim
# (Sources/FotufilmHalide/FotufilmHalideLinux.cpp, built with FOTUFILM_HALIDE_ANDROID_AOT), so the
# set is the Linux layout without CUDA. Needs a Halide SDK with the Vulkan patches (HALIDE_ROOT;
# tools/build-halide-linux.sh builds one on macOS as well).
#   tools/generate-halide-aot-android.sh [output-dir]      default build/halide-android-arm64
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
HALIDE="${HALIDE_ROOT:?set HALIDE_ROOT to a Halide SDK with the Vulkan patches}"
OUTPUT="${1:-build/halide-android-arm64}"
JOBS="${FOTUFILM_AOT_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
mkdir -p "$OUTPUT"
GENERATOR="$OUTPUT/generate-halide-aot"
STAMP="$OUTPUT/.generated-from"
# The set is current while the generator's sources, this script and the Halide compiler match.
LIBHALIDE="$(ls "$HALIDE"/lib/libHalide.{so,dylib} 2>/dev/null | head -1 || true)"
FINGERPRINT="$({
  cat tools/generate_halide_ios.cpp "$0" "$HALIDE/include/Halide.h" "$LIBHALIDE"
  find Sources/FotufilmHalide/include Sources/FotufilmHalide/Pipeline Sources/FotufilmHalide/Stages \
    -type f -name '*.h' 2>/dev/null | sort | xargs cat
  env | grep '^FOTUFILM_' | grep -v '^FOTUFILM_AOT_JOBS=' | sort || true
} | shasum -a 256 | cut -c1-32)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$FINGERPRINT" ]]; then
  echo "Android kernels in $OUTPUT are current."
  exit 0
fi
rm -f "$STAMP"
echo "Building the Halide generator…"
"${CXX:-clang++}" -std=c++17 -O2 -I"$HALIDE/include" -ISources/FotufilmHalide/include \
  tools/generate_halide_ios.cpp -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -lpthread \
  -o "$GENERATOR"
VARIANTS="$("$GENERATOR" "$OUTPUT" --count)"
echo "Generating Vulkan kernels: $VARIANTS variants, $JOBS at a time…"
seq 0 $((VARIANTS - 1)) | xargs -P "$JOBS" -I{} \
  "$GENERATOR" "$OUTPUT" --android-vulkan --prefix=fotufilm_aot_vulkan_ "--variant={}"
"$GENERATOR" "$OUTPUT" --android-vulkan --prefix=fotufilm_aot_ --extras
cp "$HALIDE/include/HalideBuffer.h" "$HALIDE/include/HalideRuntime.h" \
   "$HALIDE/include/HalideRuntimeVulkan.h" "$OUTPUT/"
echo "$FINGERPRINT" > "$STAMP"
echo "Wrote Android kernels to $OUTPUT"
