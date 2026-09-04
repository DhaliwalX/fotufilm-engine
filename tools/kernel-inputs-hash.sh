#!/bin/bash
# One line out: a content hash of everything a generated AOT kernel directory is a function of.
#
# The build scripts key their kernel directories on this so an unchanged engine costs nothing:
# eight of a ten-minute build was regenerating 128 archives identical to the ones already on
# disk. Content-keyed, not existence-keyed — the Android build's "skip if the .a is there" has
# already shipped a schedule edit that never made it into a phone, and a hash cannot go stale.
#
#   $1  the Halide prefix (its library version is an input: a new Halide emits new code)
#   $2  a free-form platform key — the target and SDK version the caller compiles for
#   $3  --kernels to hash only what the *generated archives* are a function of
#
# The two modes exist because the directory holds two kinds of output with very different prices.
# The archives take twelve minutes and depend on the generator and the pipeline definitions; the
# three objects beside them take half a minute and depend on the shim and the benchmark as well.
# Hashing both together made an edit to the shim — which no kernel is a function of — regenerate
# every archive, and made a *failed* shim compile discard twelve minutes of correct generation,
# since nothing was stamped until the whole block had succeeded. Two hashes, two stamps.
set -euo pipefail
cd "$(dirname "$0")/.."
KERNELS_ONLY=false
[[ "${3:-}" == "--kernels" ]] && KERNELS_ONLY=true
{
  # Every Halide-side source and the generator. Sorted so the hash does not follow the
  # filesystem's mood.
  if $KERNELS_ONLY; then
    # Neither excluded file is included by the generator — the archives are emitted from
    # `FotufilmHalideMetal.cpp` alone — so neither can change what generation produces.
    find Sources/FotufilmHalide -type f \
      \( -name '*.cpp' -o -name '*.h' -o -name '*.mm' \) \
      ! -name 'FotufilmHalideIOS.cpp' ! -name 'FotufilmMetalGrain.mm' -print0
  else
    find Sources/FotufilmHalide -type f \
      \( -name '*.cpp' -o -name '*.h' -o -name '*.mm' \) -print0
  fi | sort -z | xargs -0 shasum -a 256
  shasum -a 256 tools/generate_halide_ios.cpp
  # The shim and the benchmark are compiled into the directory but no archive is a function of
  # them, so they are inputs to the objects' stamp only.
  $KERNELS_ONLY || shasum -a 256 Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
    Sources/FotufilmHalide/FotufilmMetalGrain.mm
  if ! $KERNELS_ONLY && [[ -f ios/FotufilmApp/MatrixBenchmark.cpp ]]; then
    shasum -a 256 ios/FotufilmApp/MatrixBenchmark.cpp
  fi
  # The still-fast bits are baked into both the generated schedules and the shim.
  echo "still-fast=${FOTUFILM_STILL_FAST:-}"
  # Schedule overrides the generator reads from its own environment. They change the emitted
  # Metal without changing a byte of source, so a stamp that ignored them would call a sweep's
  # kernels current and hand back the previous tiling's archives.
  echo "gpu-tile=${FOTUFILM_GPU_TILE:-}/${FOTUFILM_GPU_TILE_X:-}/${FOTUFILM_GPU_TILE_Y:-}"
  echo "halide=$(basename "$(ls "$1"/lib/libHalide.*.dylib 2>/dev/null | head -1)")"
  echo "platform=$2"
} | shasum -a 256 | cut -d' ' -f1
