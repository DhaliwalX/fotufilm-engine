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
  -ffile-prefix-map="$PWD"=Fotufilm \
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

python3 tools/compile-if-needed.py xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -ISources/FotufilmHalide/include \
  -Xcc -fmodule-map-file="$OBJ/module.modulemap" \
  -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
  -O -whole-module-optimization -g -parse-as-library \
  -file-prefix-map "$PWD=Fotufilm" \
  -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
  -module-name FotufilmHost -emit-object \
  "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
  Sources/FotufilmMetal/*.swift \
  Sources/FotufilmImaging/*.swift \
  Sources/FotufilmEditModel/*.swift \
  Sources/FotufilmStockMatch/*.swift \
  Sources/FotufilmPlugins/*.swift \
  Sources/FotufilmUpdate/*.swift \
  Sources/FotufilmHost/*.swift \
  -o "$OBJ/FotufilmHost.o"

xcrun swiftc -sdk "$SDK" -target arm64-apple-macos14.0 -emit-library \
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideIOS.o" "$KERNELS"/*.a \
  -Xlinker -lc++ -Xlinker -dead_strip \
  -Xlinker -exported_symbols_list -Xlinker "$OBJ/exports.txt" \
  -Xlinker -install_name -Xlinker @rpath/libfotufilm.dylib \
  -framework Metal -framework CoreImage -framework Accelerate -framework QuartzCore \
  -framework ImageIO -framework CoreGraphics -framework CoreVideo -framework AVFoundation \
  -o "$LIBRARY"

# Symbols for crash reports stay beside the library, never in it: the shipped copy keeps only the
# C interface it exports.
xcrun dsymutil "$LIBRARY" -o "$LIBRARY.dSYM"
xcrun strip -S -x "$LIBRARY"

# The films, the reflectance prior and the camera profiles the engine reads from its bundle.
tools/copy-shipping-resources.sh "$OUT/Resources" --camera-profiles >/dev/null
# File › Use Sample Photo: the Mac app's generated chart, no photography in it.
swift tools/generate-example-image.swift "$OUT/Resources/sample.png"
echo "Built $LIBRARY"
