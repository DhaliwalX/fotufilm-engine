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
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideLinux.o" "$KERNELS"/*.a \
  -Xlinker --gc-sections -Xlinker --version-script="$OBJ/exports.map" \
  -Xlinker -soname -Xlinker libfotufilm.so \
  -lFoundationNetworking -l_CFURLSessionInterface -lCoreFoundation -l_FoundationCollections \
  -lswiftSynchronization -l_FoundationICU -l_FoundationCShims -lcurl -lstdc++ -ldl -lpthread \
  -o "$LIBRARY"

# Symbols for crash reports stay beside the library, never in it.
objcopy --only-keep-debug "$LIBRARY" "$LIBRARY.debug"
strip --strip-debug --strip-unneeded "$LIBRARY"
objcopy --add-gnu-debuglink="$LIBRARY.debug" "$LIBRARY"

# The films, the reflectance prior and the camera profiles the engine reads from beside it.
tools/copy-shipping-resources.sh "$OUT/Resources" --camera-profiles >/dev/null
echo "Built $LIBRARY"
