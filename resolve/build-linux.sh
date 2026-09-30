#!/bin/bash
# Builds the OFX plugin for Linux hosts (DaVinci Resolve reads /usr/OFX/Plugins):
# build/resolve/Fotufilm.ofx.bundle, with the plugin in Contents/Linux-x86-64. The same plugin and
# bridge as the Mac's (resolve/build.sh), developing on the desktop graph ahead-of-time compiled
# for CUDA and Vulkan (FotufilmHalideLinux.cpp, as the Linux app does), with the Swift runtime
# linked in and nothing exported but the two OFX entry points.
#   HALIDE_ROOT=… resolve/build-linux.sh [--test] [--install]
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

BUNDLE="build/resolve/Fotufilm.ofx.bundle"
PLATFORM_DIR="Linux-x86-64"
OBJ="build/resolve/obj-linux"
KERNELS="${FOTUFILM_LINUX_KERNELS:-build/halide-linux-x86_64}"
CXX="${CXX:-clang++}"

# The version the host reads from the plugin, from version.env as on the Mac; see resolve/build.sh
# for why the major stays 1.
source version.env
VERSION_MAJOR="${MARKETING_VERSION%%.*}"
VERSION_MINOR="${MARKETING_VERSION#*.}"
VERSION_MINOR="${VERSION_MINOR%%.*}"
[[ "$MARKETING_VERSION" == *.* && "$VERSION_MAJOR" == 1 && "$VERSION_MINOR" =~ ^[0-9]+$ ]] || {
  echo "error: MARKETING_VERSION \"$MARKETING_VERSION\" must be 1.<minor>; see resolve/build.sh" >&2
  exit 1
}
VERSION_DEFINES=(-DFOTUFILM_VERSION_MAJOR="$VERSION_MAJOR" -DFOTUFILM_VERSION_MINOR="$VERSION_MINOR")

[[ -f "$KERNELS/fotufilm_aot_runtime.a" ]] || tools/generate-halide-aot-linux.sh "$KERNELS"
rm -rf "$BUNDLE"
mkdir -p "$OBJ" "$BUNDLE/Contents/$PLATFORM_DIR" "$BUNDLE/Contents/Resources"

"$CXX" -std=c++17 -O2 -g1 -fPIC \
  -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -c \
  -ffile-prefix-map="$PWD"=Fotufilm \
  -DFOTUFILM_HALIDE_LINUX_AOT=1 -DFOTUFILM_TRANSPORT_REFERENCE_STUBS=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include -ISources/FotufilmHalide \
  Sources/FotufilmHalide/FotufilmHalideLinux.cpp \
  -o "$OBJ/FotufilmHalideLinux.o"

for source in FotufilmPlugin WorkingSpace; do
  "$CXX" -std=c++17 -O2 -g1 -fPIC -ffunction-sections -fdata-sections -c \
    -ffile-prefix-map="$PWD"=Fotufilm "${VERSION_DEFINES[@]}" \
    -Iresolve "resolve/$source.cpp" -o "$OBJ/$source.o"
done

# The Mac's module less Metal: FotufilmBridgeRenderer.swift answers with the Linux kernels.
swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -ISources/FotufilmHalide/include \
  -swift-version 5 -O -whole-module-optimization -g -parse-as-library \
  -file-prefix-map "$PWD=Fotufilm" \
  -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
  -module-name FotufilmOFX -emit-object -Xcc -fPIC \
  "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
  Sources/FotufilmEditModel/*.swift resolve/FotufilmBridge.swift resolve/FotufilmBridgeControls.swift \
  resolve/FotufilmBridgeRenderer.swift resolve/Generated/FotufilmBridgeSlots.swift \
  -o "$OBJ/FotufilmSwift.o"

cat > "$OBJ/exports.map" <<'MAP'
{ global: OfxGetPlugin; OfxGetNumberOfPlugins; local: *; };
MAP
ENGINE_OBJECTS=("$OBJ/FotufilmSwift.o" "$OBJ/FotufilmHalideLinux.o" "$OBJ/FotufilmPlugin.o"
                "$OBJ/WorkingSpace.o")
LINK_LIBS=(-lFoundationNetworking -l_CFURLSessionInterface -lCoreFoundation
           -l_FoundationCollections -lswiftSynchronization -l_FoundationICU -l_FoundationCShims
           -lcurl -lstdc++ -ldl -lpthread)
PLUGIN="$BUNDLE/Contents/$PLATFORM_DIR/Fotufilm.ofx"
swiftc -emit-library -static-stdlib "${ENGINE_OBJECTS[@]}" "$KERNELS"/*.a \
  -Xlinker --gc-sections -Xlinker --version-script="$OBJ/exports.map" \
  -Xlinker -soname -Xlinker Fotufilm.ofx \
  "${LINK_LIBS[@]}" -o "$PLUGIN"

objcopy --only-keep-debug "$PLUGIN" "build/resolve/Fotufilm.ofx.debug"
strip --strip-debug --strip-unneeded "$PLUGIN"

EXPORTED="$(nm -D --defined-only "$PLUGIN" | awk '$2 == "T" {print $3}' | sort -u)"
if [[ "$EXPORTED" != $'OfxGetNumberOfPlugins\nOfxGetPlugin' ]]; then
  echo "error: the plugin exports more than its OFX entry points:" >&2
  echo "$EXPORTED" | sed 's/^/  /' >&2
  exit 1
fi

# The same numbers the plugin was compiled with; the bridge reads the short version back to choose
# the packs this release can open.
sed -e "/CFBundleShortVersionString/{n;s|<string>[^<]*</string>|<string>$MARKETING_VERSION</string>|;}" \
    -e "/CFBundleVersion</{n;s|<string>[^<]*</string>|<string>$CURRENT_PROJECT_VERSION</string>|;}" \
    resolve/Info.plist > "$BUNDLE/Contents/Info.plist"
tools/copy-shipping-resources.sh "$BUNDLE/Contents/Resources" >/dev/null
echo "Built $BUNDLE"

if [[ " $* " == *" --test "* ]]; then
  for source in HostHarness ParityFrame TranscodeParity; do
    "$CXX" -std=c++17 -O2 -c "${VERSION_DEFINES[@]}" -Iresolve "resolve/tests/$source.cpp" \
      -o "$OBJ/$source.o"
  done
  swiftc -emit-executable -static-stdlib "${ENGINE_OBJECTS[@]}" \
    "$OBJ/HostHarness.o" "$OBJ/ParityFrame.o" "$OBJ/TranscodeParity.o" "$KERNELS"/*.a \
    "${LINK_LIBS[@]}" -o build/resolve/host-harness
  env -u FOTUFILM_REALTIME \
    FOTUFILM_RESOURCES="$PWD/Sources/FotufilmCore/Resources" \
    FOTUFILM_STOCKS="$PWD/Sources/FotufilmCore/Stocks" \
    build/resolve/host-harness
fi

if [[ " $* " == *" --install "* ]]; then
  PLUGINS="/usr/OFX/Plugins"
  if [[ -w "$PLUGINS" ]] || { [[ ! -e "$PLUGINS" ]] && [[ -w /usr/OFX || -w /usr ]]; }; then
    mkdir -p "$PLUGINS" && rm -rf "$PLUGINS/Fotufilm.ofx.bundle" && cp -R "$BUNDLE" "$PLUGINS/"
  else
    sudo mkdir -p "$PLUGINS"
    sudo rm -rf "$PLUGINS/Fotufilm.ofx.bundle"
    sudo cp -R "$BUNDLE" "$PLUGINS/"
  fi
  echo "Installed $PLUGINS/Fotufilm.ofx.bundle — restart Resolve to pick it up."
fi
