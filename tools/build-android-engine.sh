#!/bin/bash
# Builds libfotufilm.so, the engine behind fotufilm.h, for the Flutter editor on Android (arm64).
# It is the Linux desktop engine (tools/build-desktop-engine-linux.sh) cross-compiled: the desktop
# graph's ahead-of-time Vulkan kernels behind the Linux shim, the same Swift engine, photographs
# through the portable codecs and movies through FFmpeg, loaded when first asked for. The Swift
# runtime and FFmpeg ride beside it in the APK; the films and camera profiles go in as assets,
# which the app unpacks before it opens the library (flutter/android/.../EngineResources.kt).
#
#   HALIDE_ROOT=… tools/build-android-engine.sh
#
# Needs the Android NDK (ANDROID_NDK_HOME, or the newest under ANDROID_HOME/ndk), a swift.org
# toolchain and its matching Swift SDK for Android (SWIFT_TOOLCHAIN, SWIFT_SDK), a Halide with the
# Vulkan patches for the kernels (tools/build-halide-linux.sh builds one on macOS too), and the
# codecs and FFmpeg for Android (tools/build-android-codecs.sh, in FOTUFILM_ANDROID_DEPS).
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

TRIPLE=aarch64-unknown-linux-android28
ABI=arm64-v8a
OUT="flutter/build/android-engine"
OBJ="build/android-engine/obj"
KERNELS="${FOTUFILM_ANDROID_KERNELS:-build/halide-android-arm64}"
DEPS="${FOTUFILM_ANDROID_DEPS:-build/android-deps}/arm64"
LIBRARY="$OUT/jniLibs/$ABI/libfotufilm.so"
mkdir -p "$OBJ" "$OUT/jniLibs/$ABI"

# --- The toolchains -------------------------------------------------------------------------------
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_SDK"/ndk/*/ 2>/dev/null | sort -V | tail -1)}"
NDK="${NDK%/}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[[ -d "$NDK_BIN" ]] || NDK_BIN="$NDK/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin"
[[ -x "$NDK_BIN/clang++" ]] || { echo "error: no Android NDK (set ANDROID_NDK_HOME)" >&2; exit 1; }
CXX="$NDK_BIN/aarch64-linux-android28-clang++"
CC="$NDK_BIN/aarch64-linux-android28-clang"

TOOLCHAIN="${SWIFT_TOOLCHAIN:-/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain}"
SWIFTC="$TOOLCHAIN/usr/bin/swiftc"
[[ -x "$SWIFTC" ]] || {
  echo "error: set SWIFT_TOOLCHAIN to a swift.org toolchain matching the Swift SDK" >&2
  echo "       (Xcode's Swift cannot read the SDK's modules)" >&2
  exit 1; }
SWIFT_SDK="${SWIFT_SDK:-swift-6.3.3-RELEASE_android}"
BUNDLE="$HOME/.swiftpm/swift-sdks/$SWIFT_SDK.artifactbundle/swift-android"
[[ -d "$BUNDLE" ]] || BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/$SWIFT_SDK.artifactbundle/swift-android"
[[ -d "$BUNDLE" ]] || { echo "error: Swift SDK $SWIFT_SDK is not installed" >&2; exit 1; }
SWIFT_RESOURCES="$BUNDLE/swift-resources/usr/lib/swift-aarch64"
# The SDK's sysroot and clang headers are links into an NDK, made by its setup script; made again
# when they lead to another NDK than this one, or nowhere.
SYSROOT="$BUNDLE/ndk-sysroot"
NDK_SYSROOT="$NDK/toolchains/llvm/prebuilt/$(basename "$(dirname "$NDK_BIN")")/sysroot"
if [[ "$(readlink "$SYSROOT/usr/include" 2>/dev/null)" != "$NDK_SYSROOT/usr/include" \
      || ! -f "$SWIFT_RESOURCES/clang/include/stddef.h" ]]; then
  (cd "$BUNDLE" && ANDROID_NDK_HOME="$NDK" bash scripts/setup-android-sdk.sh)
fi

# --- 1. The kernels -------------------------------------------------------------------------------
if [[ -n "${HALIDE_ROOT:-}" || ! -f "$KERNELS/fotufilm_aot_runtime.a" ]]; then
  tools/generate-halide-aot-android.sh "$KERNELS"
fi
CFLAGS_COMMON=(-O2 -g1 -fPIC -fvisibility=hidden -fvisibility-inlines-hidden
  -ffunction-sections -fdata-sections -ffile-prefix-map="$PWD"=Fotufilm
  # The kernels and codecs can live outside the checkout; their headers are named relative too.
  -ffile-prefix-map="$(cd "$KERNELS" && pwd -P)"=kernels
  -ffile-prefix-map="$(cd "$DEPS" 2>/dev/null && pwd -P || echo "$DEPS")"=android-deps)
echo "Compiling the Halide shim…"
"$CXX" -std=c++17 "${CFLAGS_COMMON[@]}" -c -DFOTUFILM_HALIDE_ANDROID_AOT=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
  Sources/FotufilmHalide/FotufilmHalideLinux.cpp -o "$OBJ/FotufilmHalideLinux.o"

# --- 2. The codecs and FFmpeg's headers -----------------------------------------------------------
[[ -f "$DEPS/lib/libjpeg.a" ]] || {
  echo "error: no Android codecs in $DEPS (run tools/build-android-codecs.sh)" >&2; exit 1; }
CODEC_CFLAGS=(-I"$DEPS/include/libraw" -I"$DEPS/include" -I"$DEPS/include/libpng16"
  -I"$DEPS/include/OpenEXR" -I"$DEPS/include/Imath" -pthread)
echo "Compiling the codecs…"
rm -f "$OBJ"/codecs-*.o "$OBJ"/video-*.o
for source in Sources/CFotufilmCodecs/*.cpp; do
  "$CXX" -std=c++17 "${CFLAGS_COMMON[@]}" -c "${CODEC_CFLAGS[@]}" \
    -ISources/CFotufilmCodecs/include "$source" -o "$OBJ/codecs-$(basename "$source" .cpp).o"
done
for source in Sources/CFotufilmVideo/*.cpp; do
  "$CXX" -std=c++17 "${CFLAGS_COMMON[@]}" -c -I"$DEPS/include" \
    -ISources/CFotufilmVideo/include "$source" -o "$OBJ/video-$(basename "$source" .cpp).o"
done

# --- 3. The Swift engine --------------------------------------------------------------------------
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
echo "Compiling the Swift engine…"
"$SWIFTC" -target "$TRIPLE" -sdk "$SYSROOT" -resource-dir "$SWIFT_RESOURCES" \
  ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
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

# --- 4. Link --------------------------------------------------------------------------------------
# By the NDK's clang++ rather than swiftc: the compiler-rt builtins and libunwind for Android are
# the NDK's (as android/tools/build-engine.sh in the apps finds). The codecs are linked in; FFmpeg
# is opened at run time.
echo "Linking libfotufilm.so…"
# In the order each needs the next (tools/build-android-codecs.sh builds them).
CODEC_LIBS=(-L"$DEPS/lib" -lraw_r -lheif -lde265 -ltiff -lpng16 -ljpeg -llcms2
  -lOpenEXR-3_5 -lOpenEXRUtil-3_5 -lOpenEXRCore-3_5 -lIex-3_5 -lIlmThread-3_5 -lImath-3_2)
"$CXX" -shared -fPIC -o "$LIBRARY" \
  "$SWIFT_RESOURCES/android/aarch64/swiftrt.o" \
  "$OBJ/FotufilmHost.o" "$OBJ/FotufilmHalideLinux.o" "$OBJ"/codecs-*.o "$OBJ"/video-*.o \
  "$KERNELS"/*.a \
  "${CODEC_LIBS[@]}" \
  -L"$SWIFT_RESOURCES/android" \
  -lswiftCore -lswiftAndroid -lswift_Concurrency -lswiftSynchronization -lswift_StringProcessing \
  -lswift_RegexParser -lFoundation -lFoundationEssentials -lFoundationInternationalization \
  -lFoundationNetworking \
  -l_FoundationICU -ldispatch -lswiftDispatch -lBlocksRuntime \
  -lz -llog -landroid -ldl -lm \
  -Wl,--gc-sections -Wl,--version-script="$OBJ/exports.map" \
  -Wl,-soname,libfotufilm.so -Wl,--build-id=sha1 -Wl,-z,max-page-size=16384

# --- 5. What rides beside it ----------------------------------------------------------------------
# The Swift runtime and the C++ runtime it needs, walked from the library's DT_NEEDED entries, and
# FFmpeg's libraries, which the engine opens by name when a movie is first asked for.
echo "Copying the runtimes…"
python3 - "$OUT/jniLibs/$ABI" "$NDK_BIN/llvm-readelf" "$SWIFT_RESOURCES/android" \
  "$NDK_SYSROOT/usr/lib/aarch64-linux-android" "$DEPS/lib" <<'PYTHON'
import pathlib, shutil, subprocess, sys
out, readelf = pathlib.Path(sys.argv[1]), sys.argv[2]
sources = [pathlib.Path(p) for p in sys.argv[3:]]
def needed(path):
    listing = subprocess.run([readelf, "-d", str(path)], capture_output=True, text=True).stdout
    return [l.split("[")[1].split("]")[0] for l in listing.splitlines() if "NEEDED" in l and "[" in l]
roots = ["libfotufilm.so"] + [p.name for p in pathlib.Path(sys.argv[5]).glob("lib*.so")]
seen, queue = set(), list(roots)
while queue:
    name = queue.pop()
    if name in seen:
        continue
    seen.add(name)
    local = out / name
    if not local.exists() or name != "libfotufilm.so":
        for source in sources:
            if (source / name).is_file():
                shutil.copy2((source / name).resolve(), local)
                break
    if local.exists():
        queue += needed(local)
for stale in out.glob("*.so"):
    if stale.name not in seen:
        stale.unlink()
total = sum(p.stat().st_size for p in out.glob("*.so"))
print(f"  {len(list(out.glob('*.so')))} libraries, {total / 1048576:.1f} MB")
PYTHON
"$NDK_BIN/llvm-strip" --strip-unneeded "$LIBRARY"

# The films, the reflectance prior and the camera profiles, as the app's assets.
rm -rf "$OUT/assets/fotufilm"
tools/copy-shipping-resources.sh "$OUT/assets/fotufilm" --camera-profiles >/dev/null
echo "Built $LIBRARY"
