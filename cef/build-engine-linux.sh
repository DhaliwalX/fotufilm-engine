#!/bin/bash
# Builds libfotufilm.so, the engine behind fotufilm.h, for Fotufilm Desktop on Linux. Like the Mac
# library it links ahead-of-time Halide kernels, here the desktop graph for CUDA and for Vulkan
# (FotufilmHalideLinux.cpp chooses between them when the app starts), so no develop waits on a
# compiler and no Halide compiler ships. It exports nothing but the C interface, and carries the
# Swift runtime inside it.
#   HALIDE_ROOT=… cef/build-engine-linux.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

OUT="build/cef-engine"
OBJ="$OUT/obj"
KERNELS="${FOTUFILM_LINUX_KERNELS:-build/halide-linux-x86_64}"
LIBRARY="$OUT/libfotufilm.so"
mkdir -p "$OBJ"

# Generating both sets takes a while on a large machine; they are regenerated when missing.
[[ -f "$KERNELS/fotufilm_aot_runtime.a" ]] || tools/generate-halide-aot-linux.sh "$KERNELS"

"${CXX:-clang++}" -std=c++17 -O2 -g1 -fPIC \
  -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
  -ffile-prefix-map="$PWD"=Fotufilm \
  -DFOTUFILM_HALIDE_LINUX_AOT=1 -DFOTUFILM_TRANSPORT_REFERENCE_STUBS=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
  Sources/FotufilmHalide/FotufilmHalideLinux.cpp \
  -o "$OBJ/FotufilmHalideLinux.o"

# Photographs and stills through the system's codec libraries (Sources/CFotufilmCodecs), linked
# dynamically: the AppImage carries them.
CODEC_PACKAGES=(libraw_r lcms2 libjpeg libpng libtiff-4 libheif OpenEXR)
pkg-config --exists "${CODEC_PACKAGES[@]}" || {
  echo "error: the codec development packages are missing (cef/README.md lists them)" >&2
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
  echo "error: the FFmpeg development packages are missing (cef/README.md lists them)" >&2
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
  -D FOTUFILM_PACK_KEY_MATERIAL \
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
  "$FOTUFILM_PACK_KEY_SOURCE" \
  -o "$OBJ/FotufilmHost.o"

swiftc -emit-library -static-stdlib \
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideLinux.o" "$OBJ"/codecs-*.o "$OBJ"/video-*.o \
  "$KERNELS"/*.a \
  -Xlinker --gc-sections -Xlinker --version-script="$OBJ/exports.map" \
  -Xlinker -soname -Xlinker libfotufilm.so \
  -lFoundationNetworking -l_CFURLSessionInterface -lCoreFoundation -l_FoundationCollections \
  -lswiftSynchronization -l_FoundationICU -l_FoundationCShims -lcurl \
  "${CODEC_LIBS[@]}" -lstdc++ -ldl -lpthread \
  -o "$LIBRARY"

# Symbols for crash reports stay beside the library, never in it.
objcopy --only-keep-debug "$LIBRARY" "$LIBRARY.debug"
strip --strip-debug --strip-unneeded "$LIBRARY"
objcopy --add-gnu-debuglink="$LIBRARY.debug" "$LIBRARY"

# The films, the reflectance prior and the camera profiles the engine reads from beside it.
tools/copy-shipping-resources.sh "$OUT/Resources" --camera-profiles >/dev/null
echo "Built $LIBRARY"
