#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${HALIDE_ROOT:?Set HALIDE_ROOT to a Halide SDK with the Vulkan backend}"
: "${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to an Android NDK}"
OUT="${FOTUFILM_VULKAN_OUT:-$PWD/build/vulkan-parity/android}"
TARGET="${FOTUFILM_VULKAN_TARGET:-arm-64-android-strict_float}"
mkdir -p "$OUT"
HOST_FLAGS=(-std=c++17 -O2 -I"$HALIDE_ROOT/include" -ISources/FotufilmHalide/include
    -L"$HALIDE_ROOT/lib" -lHalide "-Wl,-rpath,$HALIDE_ROOT/lib")
if [[ "$(uname -s)" == Darwin ]]; then
    HOST_FLAGS+=(-isysroot "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}")
    HOST=darwin-x86_64
else HOST=linux-x86_64; fi
"${CXX:-clang++}" "${HOST_FLAGS[@]}" tools/vulkan-parity/test-quality.cpp -o "$OUT/test-quality"
"$OUT/test-quality"
"${CXX:-clang++}" "${HOST_FLAGS[@]}" tools/vulkan-parity/generate.cpp -o "$OUT/generate"
"${CXX:-clang++}" "${HOST_FLAGS[@]}" tools/generate_halide_wasm_cpu.cpp -o "$OUT/generate-cpu"
"$OUT/generate-cpu" "$OUT" --target arm-64-android --flexible-only
for variant in vk_color vk_plain vk_mono vk_print vk_annular cpu_negative vk_negative cpu_display vk_display; do
    "$OUT/generate" "$OUT" "$TARGET" "$variant"
done
# Empty exact-mask dispatch makes the production CPU adapter use its flexible graph.
: > "$OUT/fotufilm_wasm_variants.h"
: > "$OUT/fotufilm_wasm_variants.inc"
LIBRARIES=("$OUT/vk_color.a")
for archive in "$OUT"/*.a; do
    [[ "$archive" == "$OUT/vk_color.a" ]] || LIBRARIES+=("$archive")
done
"$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android28-clang++" \
    -std=c++17 -O2 -static-libstdc++ -I"$OUT" -I"$HALIDE_ROOT/include" \
    -ISources/FotufilmHalide/include tools/vulkan-parity/main.cpp web/engine/fotufilm_wasm_cpu.cpp \
    "${LIBRARIES[@]}" -ldl -llog -o "$OUT/parity"
"${CXX:-clang++}" "${HOST_FLAGS[@]}" tools/vulkan-parity/generate-spatial.cpp -o "$OUT/generate-spatial"
"$OUT/generate-spatial" "$OUT" arm-64-android
"$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android28-clang++" \
    -std=c++17 -O2 -static-libstdc++ -I"$OUT" -I"$HALIDE_ROOT/include" \
    -ISources/FotufilmHalide/include tools/vulkan-parity/spatial.cpp \
    "$OUT/vk_color.a" "$OUT/cpu_spatial.a" "$OUT/vk_spatial.a" -ldl -llog -o "$OUT/spatial"
"${CXX:-clang++}" "${HOST_FLAGS[@]}" tools/vulkan-parity/generate-uniforms.cpp -o "$OUT/generate-uniforms"
"$OUT/generate-uniforms" "$OUT/uniforms" arm-64-android
"$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android28-clang++" \
    -std=c++17 -O2 -static-libstdc++ -I"$OUT" -I"$HALIDE_ROOT/include" \
    tools/vulkan-parity/uniforms.cpp "$OUT/vk_color.a" "$OUT/uniforms.a" \
    -ldl -llog -o "$OUT/test-uniforms"
printf '%s\n' "$TARGET" > "$OUT/target.txt"
