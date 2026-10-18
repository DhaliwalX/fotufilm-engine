#!/bin/bash
# Builds libfotufilm.so, the engine behind fotufilm.h, for Fotufilm Desktop on Linux. Like the Mac
# library it links ahead-of-time Halide kernels, here the desktop graph for CUDA and for Vulkan
# (FotufilmHalideLinux.cpp chooses between them when the app starts), so no develop waits on a
# compiler and no Halide compiler ships. It exports nothing but the C interface, and carries the
# Swift runtime inside it where the toolchain has a static one (FOTUFILM_SWIFT_STDLIB below).
#   HALIDE_ROOT=… tools/build-desktop-engine-linux.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

OUT="build/engine"
OBJ="$OUT/obj"
KERNELS="${FOTUFILM_LINUX_KERNELS:-build/halide-linux-x86_64}"
LIBRARY="$OUT/libfotufilm.so"
mkdir -p "$OBJ"

# Generating both sets takes a while on a large machine; the script regenerates them only when the
# generator's sources or the Halide compiler changed since the last run. Kernels built elsewhere
# (FOTUFILM_LINUX_KERNELS without HALIDE_ROOT) are used as they are.
if [[ -n "${HALIDE_ROOT:-}" || ! -f "$KERNELS/fotufilm_aot_runtime.a" ]]; then
  tools/generate-halide-aot-linux.sh "$KERNELS"
fi

"${CXX:-clang++}" -std=c++17 -O2 -g1 -fPIC \
  -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
  -ffile-prefix-map="$PWD"=Fotufilm \
  -DFOTUFILM_HALIDE_LINUX_AOT=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
  Sources/FotufilmHalide/FotufilmHalideLinux.cpp \
  -o "$OBJ/FotufilmHalideLinux.o"

# Photographs and stills through the system's codec libraries (Sources/CFotufilmCodecs), linked
# dynamically: the AppImage carries them.
CODEC_PACKAGES=(libraw_r lcms2 libjpeg libpng libtiff-4 libheif OpenEXR)
pkg-config --exists "${CODEC_PACKAGES[@]}" || {
  echo "error: the codec development packages are missing (flutter/README.md lists them)" >&2
  exit 1
}
read -r -a CODEC_CFLAGS <<< "$(pkg-config --cflags "${CODEC_PACKAGES[@]}")"
# Handed to the linker in order, so --as-needed drops the libraries nothing calls.
CODEC_LIBS=(-Xlinker --as-needed)
for flag in $(pkg-config --libs "${CODEC_PACKAGES[@]}"); do
  [[ "$flag" == -l* || "$flag" == -L* ]] && CODEC_LIBS+=(-Xlinker "$flag")
done
CODEC_LIBS+=(-Xlinker --no-as-needed)
for source in Sources/CFotufilmCodecs/*.cpp; do
  "${CXX:-clang++}" -std=c++17 -O2 -g1 -fPIC \
    -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
    -ffile-prefix-map="$PWD"=Fotufilm "${CODEC_CFLAGS[@]}" -ISources/CFotufilmCodecs/include \
    "$source" -o "$OBJ/codecs-$(basename "$source" .cpp).o"
done

# Movies through the system's FFmpeg (Sources/CFotufilmVideo): compiled against its headers,
# loaded when first asked for, never linked or carried.
VIDEO_PACKAGES=(libavformat libavcodec libavutil libswscale libswresample)
pkg-config --exists "${VIDEO_PACKAGES[@]}" || {
  echo "error: the FFmpeg development packages are missing (flutter/README.md lists them)" >&2
  exit 1
}
read -r -a VIDEO_CFLAGS <<< "$(pkg-config --cflags "${VIDEO_PACKAGES[@]}")"
for source in Sources/CFotufilmVideo/*.cpp; do
  "${CXX:-clang++}" -std=c++17 -O2 -g1 -fPIC \
    -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
    -ffile-prefix-map="$PWD"=Fotufilm ${VIDEO_CFLAGS[@]+"${VIDEO_CFLAGS[@]}"} \
    -ISources/CFotufilmVideo/include "$source" -o "$OBJ/video-$(basename "$source" .cpp).o"
done

cat > "$OBJ/module.modulemap" <<MAP
module CFotufilmHost {
  header "$PWD/Sources/CFotufilmHost/include/fotufilm.h"
  export *
}
MAP
{
  echo "{ global:"
  grep -o 'fotufilm_[a-z0-9_]*(' Sources/CFotufilmHost/include/fotufilm.h | tr -d '(' | sort -u \
    | sed 's/$/;/'
  echo "local: *; };"
} > "$OBJ/exports.map"

# One module, as on the Mac. Metal's sources stay out; Linux develops through the kernels above.
swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -ISources/FotufilmHalide/include \
  -Xcc -fmodule-map-file="$OBJ/module.modulemap" \
  -Xcc -fmodule-map-file="$PWD/Sources/CFotufilmCodecs/include/module.modulemap" \
  -Xcc -fmodule-map-file="$PWD/Sources/CFotufilmVideo/include/module.modulemap" \
  -swift-version 5 -O -whole-module-optimization -g -parse-as-library \
  -file-prefix-map "$PWD=Fotufilm" \
  -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
  -module-name FotufilmHost -emit-object -Xcc -fPIC \
  "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
  Sources/FotufilmImaging/*.swift \
  Sources/FotufilmEditModel/*.swift \
  Sources/FotufilmStockMatch/*.swift \
  Sources/FotufilmPlugins/*.swift \
  Sources/FotufilmUpdate/*.swift \
  Sources/FotufilmHost/*.swift \
  -o "$OBJ/FotufilmHost.o"

# The Swift runtime and Foundation go inside the library, so it runs on any distribution. A
# toolchain without a static runtime (lib/swift_static), such as Fedora's swift-lang, links the
# system's instead: that library runs only where the same Swift is installed, and the AppImage
# refuses it. FOTUFILM_SWIFT_STDLIB=static or dynamic chooses.
SWIFT_STDLIB="${FOTUFILM_SWIFT_STDLIB:-}"
if [[ -z "$SWIFT_STDLIB" ]]; then
  SWIFT_RESOURCES="$(swiftc -print-target-info \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
  SWIFT_STDLIB=dynamic
  [[ -d "$SWIFT_RESOURCES/../swift_static" ]] && SWIFT_STDLIB=static
fi
case "$SWIFT_STDLIB" in
  static)
    STDLIB_FLAGS=(-static-stdlib
      -lFoundationNetworking -l_CFURLSessionInterface -lCoreFoundation -l_FoundationCollections
      -lswiftSynchronization -l_FoundationICU -l_FoundationCShims -lcurl) ;;
  dynamic)
    echo "warning: linking the system's Swift runtime; this libfotufilm.so is not portable" >&2
    STDLIB_FLAGS=() ;;
  *)
    echo "error: FOTUFILM_SWIFT_STDLIB must be static or dynamic" >&2
    exit 1 ;;
esac
# $ORIGIN: the Flutter app loads the engine by path, so the libraries an AppImage carries beside it
# are found from the library itself.
swiftc -emit-library ${STDLIB_FLAGS[@]+"${STDLIB_FLAGS[@]}"} \
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideLinux.o" "$OBJ"/codecs-*.o "$OBJ"/video-*.o \
  "$KERNELS"/*.a \
  -Xlinker --gc-sections -Xlinker --version-script="$OBJ/exports.map" \
  -Xlinker -soname -Xlinker libfotufilm.so \
  -Xlinker -rpath -Xlinker '$ORIGIN' \
  "${CODEC_LIBS[@]}" -lstdc++ -ldl -lpthread \
  -o "$LIBRARY"

# Symbols for crash reports stay beside the library, never in it.
objcopy --only-keep-debug "$LIBRARY" "$LIBRARY.debug"
strip --strip-debug --strip-unneeded "$LIBRARY"
objcopy --add-gnu-debuglink="$LIBRARY.debug" "$LIBRARY"

# The films, the reflectance prior and the camera profiles the engine reads from beside it.
tools/copy-shipping-resources.sh "$OUT/Resources" --camera-profiles >/dev/null
echo "Built $LIBRARY"
