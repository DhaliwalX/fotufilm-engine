#!/bin/bash
# Builds libfotufilm.dylib, the engine behind fotufilm.h, for Fotufilm Desktop. Like the Mac app it
# links the ahead-of-time Halide kernels, so no develop ever waits on a compiler, and it exports
# nothing but the C interface.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

OUT="build/cef-engine"
OBJ="$OUT/obj"
KERNELS="build/halide-macos"
LIBRARY="$OUT/libfotufilm.dylib"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OBJ"

tools/generate-halide-aot.sh macos "$KERNELS"

python3 tools/compile-if-needed.py xcrun clang++ -std=c++17 -O2 -gline-tables-only \
  -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
  -isysroot "$SDK" -target arm64-apple-macos14.0 \
  -DFOTUFILM_HALIDE_IOS_AOT=1 -DFOTUFILM_TRANSPORT_REFERENCE_STUBS=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  -o "$OBJ/FotufilmHalideIOS.o"

# One module, as the Mac app is built: the header reaches Swift through its own module map.
cat > "$OBJ/module.modulemap" <<MAP
module CFotufilmHost {
  header "$PWD/Sources/CFotufilmHost/include/fotufilm.h"
  export *
}
MAP
nm -gU "$OBJ/FotufilmHalideIOS.o" >/dev/null
grep -o 'fotufilm_[a-z0-9_]*(' Sources/CFotufilmHost/include/fotufilm.h \
  | tr -d '(' | sort -u | sed 's/^/_/' > "$OBJ/exports.txt"

# The pack container keys the Mac app is built with (tools/desktop-build-config.sh), so the engine
# opens the same community packs and bundled vault it does (Sources/FotufilmHost/HostFilmPacks.swift).
python3 tools/compile-if-needed.py xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -D FOTUFILM_PACK_KEY_MATERIAL \
  -ISources/FotufilmHalide/include \
  -Xcc -fmodule-map-file="$OBJ/module.modulemap" \
  -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
  -O -whole-module-optimization -g -parse-as-library \
  -module-name FotufilmHost -emit-object \
  "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
  Sources/FotufilmMetal/*.swift \
  Sources/FotufilmImaging/*.swift \
  Sources/FotufilmEditModel/*.swift \
  Sources/FotufilmStockMatch/*.swift \
  Sources/FotufilmPlugins/*.swift \
  Sources/FotufilmHost/*.swift \
  "$FOTUFILM_PACK_KEY_SOURCE" \
  -o "$OBJ/FotufilmHost.o"

xcrun swiftc -sdk "$SDK" -target arm64-apple-macos14.0 -emit-library \
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideIOS.o" "$KERNELS"/*.a \
  -Xlinker -lc++ -Xlinker -dead_strip \
  -Xlinker -exported_symbols_list -Xlinker "$OBJ/exports.txt" \
  -Xlinker -install_name -Xlinker @rpath/libfotufilm.dylib \
  -framework Metal -framework CoreImage -framework Accelerate -framework QuartzCore \
  -framework ImageIO -framework CoreGraphics -framework CoreVideo -framework AVFoundation \
  -o "$LIBRARY"

# The films, the reflectance prior and the camera profiles the engine reads from its bundle.
tools/copy-shipping-resources.sh "$OUT/Resources" --camera-profiles >/dev/null
echo "Built $LIBRARY"
