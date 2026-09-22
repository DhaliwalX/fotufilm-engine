#!/bin/bash
# Match the frame fixture emitted by the browser benchmark on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || { echo "usage: $0 FRAME.pack" >&2; exit 2; }
HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build/webgpu-performance
env -u SDKROOT xcrun clang++ -std=c++17 -O2 -isysroot "$TASK_SDK" \
  -DFOTUFILM_HALIDE_ENABLED=1 -I "$HALIDE_PREFIX/include" \
  -I Sources/FotufilmHalide/include tools/benchmark-native-metal.cpp \
  Sources/FotufilmHalide/FotufilmHalideMetal.cpp \
  -L "$HALIDE_PREFIX/lib" -lHalide -Wl,-rpath,"$HALIDE_PREFIX/lib" \
  -framework Metal -framework Foundation -o build/webgpu-performance/native-metal
# Use the same curve and grain tables as the browser, without narrowing float IO.
FOTUFILM_STILL_FAST=34 build/webgpu-performance/native-metal "$1"
