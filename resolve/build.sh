#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

BUNDLE="build/resolve/Fotufilm.ofx.bundle"
ARCH_DIR="MacOS"
DSYM="build/resolve/Fotufilm.ofx.dSYM"

IDENTITY="${FOTUFILM_CODESIGN_IDENTITY:--}"

UNIVERSAL=0
[[ " $* " == *" --universal "* ]] && UNIVERSAL=1
if (( UNIVERSAL )); then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT="14.0"

# One version line for the whole product. version.env drives the Xcode targets, and this bundle is
# assembled by hand; reading it back out is what keeps the two from drifting. The marketing
# version is split into the major and minor the OfxPlugin struct carries, so the number a host
# reports for the plugin, the bundle's Info.plist and the app's own version are one number read
# from one place. The checked-in Info.plist is a convenience copy of the same numbers; the bundle
# is stamped from version.env regardless, so a stale one is reported and not fatal.
source version.env
[[ -n "$MARKETING_VERSION" && -n "$CURRENT_PROJECT_VERSION" ]] || {
  echo "error: version.env must define MARKETING_VERSION and CURRENT_PROJECT_VERSION" >&2
  exit 1
}
PROJECT_VERSION="$CURRENT_PROJECT_VERSION"
# Both halves are cut out of the one string, and `${x#*.}` on a string with no dot returns the
# string — so a bare "2" would compile as major 2, minor 2 and stamp a version nothing asked for.
# OFX treats the major as plugin identity, so that is not a cosmetic mistake.
[[ "$MARKETING_VERSION" == *.* ]] || {
  echo "error: MARKETING_VERSION \"$MARKETING_VERSION\" has no minor component; the plugin needs major.minor" >&2
  exit 1
}
VERSION_MAJOR="${MARKETING_VERSION%%.*}"
VERSION_MINOR="${MARKETING_VERSION#*.}"
VERSION_MINOR="${VERSION_MINOR%%.*}"
[[ "$VERSION_MAJOR" =~ ^[0-9]+$ && "$VERSION_MINOR" =~ ^[0-9]+$ ]] || {
  echo "error: MARKETING_VERSION \"$MARKETING_VERSION\" is not major.minor" >&2
  exit 1
}
# The major is pinned, not derived. OFX keys a saved effect on the plugin's major version, so a
# bundle that reports major 2 is a *different* plugin from com.fotufilm major 1: every
# Resolve timeline saved with the 1.x node would open with the Fotufilm effect missing. Parameter
# identity has been unchanged since 1.1 and the plugin's own comment says the major must stay 1
# while that holds. A marketing version crossing 2.0 must not silently carry the plugin with it.
if [[ "$VERSION_MAJOR" != "1" ]]; then
  echo "error: MARKETING_VERSION \"$MARKETING_VERSION\" would build the OFX plugin as major $VERSION_MAJOR, not 1." >&2
  echo "  OFX treats the major version as plugin identity: hosts match a saved effect on it, so a" >&2
  echo "  bundle reporting major $VERSION_MAJOR is a different plugin from com.fotufilm major 1 and" >&2
  echo "  every existing Resolve timeline loses its Fotufilm node." >&2
  echo "  Crossing 2.0 is a deliberate decision, not a consequence of a marketing bump: revisit this" >&2
  echo "  guard together with the parameter-identity comment on gPlugin in resolve/FotufilmPlugin.cpp" >&2
  echo "  (and decide what happens to projects saved with the 1.x node) before raising it." >&2
  exit 1
fi
VERSION_DEFINES=(-DFOTUFILM_VERSION_MAJOR="$VERSION_MAJOR" -DFOTUFILM_VERSION_MINOR="$VERSION_MINOR")
# Drift in the checked-in plist is a note, not a failure. The bundle's copy is stamped from
# version.env further down and that stamped copy is the one the Mac app compares against, so the
# values at rest here are not load-bearing. CURRENT_PROJECT_VERSION moves with every release —
# one monotonic build number shared with Xcode Cloud — and CI runs this script, so failing here
# would break the OFX harness on every bump until someone hand-edited the plist.
for key in "CFBundleShortVersionString $MARKETING_VERSION" "CFBundleVersion $PROJECT_VERSION"; do
  value="$(/usr/libexec/PlistBuddy -c "Print :${key%% *}" resolve/Info.plist 2>/dev/null || true)"
  [[ "$value" == "${key#* }" ]] || \
    echo "warning: resolve/Info.plist ${key%% *} is \"$value\" but version.env says \"${key#* }\"; the bundle will be stamped \"${key#* }\"" >&2
done

rm -rf "$BUNDLE" "$DSYM"
mkdir -p "$BUNDLE/Contents/$ARCH_DIR" "$BUNDLE/Contents/Resources"

SLICES=()
for ARCH in "${ARCHS[@]}"; do
  TARGET="$ARCH-apple-macos$DEPLOYMENT"
  OBJ="build/resolve/obj-$ARCH"
  case "$ARCH" in
    arm64)  KERNEL_PLATFORM="macos" ;;
    x86_64) KERNEL_PLATFORM="macos-intel" ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
  esac
  KERNELS="build/halide-$KERNEL_PLATFORM"

  echo "--- $ARCH ---"
  tools/generate-halide-aot.sh "$KERNEL_PLATFORM" "$KERNELS"

  rm -rf "$OBJ"; mkdir -p "$OBJ"

  xcrun clang++ -std=c++17 -O2 -gline-tables-only -flto=thin \
    -fvisibility=hidden -fvisibility-inlines-hidden \
    -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
    -fmacro-prefix-map="$PWD"=Fotufilm \
    -ffunction-sections -fdata-sections -c \
    -isysroot "$SDK" -target "$TARGET" \
    -DFOTUFILM_HALIDE_IOS_AOT=1 \
    -I"$KERNELS" -ISources/FotufilmHalide/include \
    Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
    -o "$OBJ/FotufilmHalideIOS.o"

  for source in FotufilmPlugin WorkingSpace; do
    xcrun clang++ -std=c++17 -O2 -gline-tables-only -flto=thin \
      -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
      -fmacro-prefix-map="$PWD"=Fotufilm \
      -ffunction-sections -fdata-sections -c \
      -isysroot "$SDK" -target "$TARGET" \
      "${VERSION_DEFINES[@]}" \
      -Iresolve "resolve/$source.cpp" \
      -o "$OBJ/$source.o"
  done

  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -ISources/FotufilmHalide/include \
    -sdk "$SDK" \
    -target "$TARGET" \
    -swift-version 5 \
    -O -whole-module-optimization -g -parse-as-library \
    -file-prefix-map "$PWD=Fotufilm" \
    -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
    -module-name FotufilmOFX -emit-object \
    "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
    Sources/FotufilmMetal/*.swift \
    "$FOTUFILM_PACK_KEY_SOURCE" \
    resolve/FotufilmBridge.swift \
    -o "$OBJ/FotufilmSwift.o"

  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -sdk "$SDK" \
    -target "$TARGET" \
    -emit-library \
    "$OBJ/FotufilmSwift.o" \
    "$OBJ/FotufilmHalideIOS.o" "$OBJ/FotufilmPlugin.o" "$OBJ/WorkingSpace.o" \
    "$KERNELS"/*.a \
    -Xlinker -lc++ \
    -Xlinker -dead_strip \
    -framework Metal -framework Foundation \
    -Xlinker -unexported_symbols_list -Xlinker resolve/private-symbols.txt \
    -Xlinker -install_name -Xlinker "@rpath/Fotufilm.ofx" \
    -o "$OBJ/Fotufilm.ofx"

  tools/verify-apple-aot.sh "$OBJ/Fotufilm.ofx"

  EXPORTED="$(nm -gU "$OBJ/Fotufilm.ofx" | awk '{print $3}' | sort -u)"
  EXPECTED=$'_OfxGetNumberOfPlugins\n_OfxGetPlugin'
  if [[ "$EXPORTED" != "$EXPECTED" ]]; then
    echo "error: the $ARCH slice exports more than its OFX entry points:" >&2
    comm -23 <(echo "$EXPORTED") <(echo "$EXPECTED") | sed 's/^/  /' >&2
    exit 1
  fi

  SLICES+=("$OBJ/Fotufilm.ofx")
done

if (( ${#SLICES[@]} > 1 )); then
  lipo -create "${SLICES[@]}" -output "$BUNDLE/Contents/$ARCH_DIR/Fotufilm.ofx"
else
  cp "${SLICES[0]}" "$BUNDLE/Contents/$ARCH_DIR/Fotufilm.ofx"
fi

PLUGIN="$BUNDLE/Contents/$ARCH_DIR/Fotufilm.ofx"
xcrun dsymutil "$PLUGIN" -o "$DSYM"
xcrun strip -S -x -T "$PLUGIN"

# Stripping must not widen or remove the host interface. Check the final universal binary, not only
# the unstripped slices, so every distributed architecture is covered.
EXPORTED="$(nm -gU "$PLUGIN" | awk '{print $3}' | sort -u)"
EXPECTED=$'_OfxGetNumberOfPlugins\n_OfxGetPlugin'
if [[ "$EXPORTED" != "$EXPECTED" ]]; then
  echo "error: the stripped plugin does not expose exactly its two OFX entry points:" >&2
  comm -3 <(echo "$EXPORTED") <(echo "$EXPECTED") | sed 's/^/  /' >&2
  exit 1
fi

cp resolve/Info.plist "$BUNDLE/Contents/Info.plist"
# The same numbers the plugin was compiled with, stamped into the bundle. The Mac app compares
# these against the installed copy to decide whether it is out of date, so the stamp has to
# happen before the signature seals over it.
for key in "CFBundleShortVersionString $MARKETING_VERSION" "CFBundleVersion $PROJECT_VERSION"; do
  /usr/libexec/PlistBuddy -c "Set :$key" "$BUNDLE/Contents/Info.plist"
done
tools/copy-shipping-resources.sh "$BUNDLE/Contents/Resources"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$BUNDLE"
else
  # Developer ID distribution needs a secure timestamp and hardened runtime before notarisation.
  # Do not swallow a signing failure: an artifact Resolve cannot load is not a successful build.
  codesign --force --sign "$IDENTITY" --timestamp --options runtime "$BUNDLE"
fi
codesign --verify --deep --strict "$BUNDLE"
tools/audit-apple-bundle.sh "$BUNDLE"

echo "Built $BUNDLE ($(lipo -archs "$BUNDLE/Contents/$ARCH_DIR/Fotufilm.ofx"))"

STRAY="$(otool -L "$PLUGIN" \
  | grep $'^\t' | awk '{print $1}' | sort -u \
  | grep -v '^/usr/lib/' | grep -v '^/System/Library/' | grep -v '^@rpath/Fotufilm.ofx$' || true)"
if [[ -n "$STRAY" ]]; then
  echo "error: the bundle depends on libraries it does not carry:" >&2
  echo "$STRAY" | sed 's/^/  /' >&2
  exit 1
fi

if [[ " $* " == *" --test "* ]]; then
  ARCH="$(uname -m)"
  OBJ="build/resolve/obj-$ARCH"
  case "$ARCH" in
    arm64)  KERNELS="build/halide-macos" ;;
    x86_64) KERNELS="build/halide-macos-intel" ;;
  esac
  for source in HostHarness ParityFrame TranscodeParity; do
    xcrun clang++ -std=c++17 -O2 -c \
      -isysroot "$SDK" -target "$ARCH-apple-macos$DEPLOYMENT" \
      "${VERSION_DEFINES[@]}" \
      -Iresolve "resolve/tests/$source.cpp" \
      -o "$OBJ/$source.o"
  done
  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -ISources/FotufilmHalide/include \
    -sdk "$SDK" -target "$ARCH-apple-macos$DEPLOYMENT" \
    -swift-version 5 -O -parse-as-library \
    "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
    Sources/FotufilmMetal/*.swift \
    "$FOTUFILM_PACK_KEY_SOURCE" \
    resolve/FotufilmBridge.swift \
    "$OBJ/FotufilmHalideIOS.o" "$OBJ/FotufilmPlugin.o" "$OBJ/WorkingSpace.o" \
    "$OBJ/HostHarness.o" "$OBJ/ParityFrame.o" "$OBJ/TranscodeParity.o" \
    "$KERNELS"/*.a \
    -Xlinker -lc++ \
    -framework Metal -framework Foundation \
    -o "build/resolve/host-harness"
  env -u FOTUFILM_REALTIME \
    FOTUFILM_RESOURCES="$PWD/Sources/FotufilmCore/Resources" \
    FOTUFILM_STOCKS="$PWD/Sources/FotufilmCore/Stocks" \
    "build/resolve/host-harness"
  env -u FOTUFILM_BENCHMARK_4K \
    FOTUFILM_REALTIME=0 \
    FOTUFILM_RESOURCES="$PWD/Sources/FotufilmCore/Resources" \
    FOTUFILM_STOCKS="$PWD/Sources/FotufilmCore/Stocks" \
    "build/resolve/host-harness"
fi

if [[ " $* " == *" --install "* ]]; then
  PLUGINS="/Library/OFX/Plugins"
  DESTINATION="$PLUGINS/Fotufilm.ofx.bundle"
  if [[ -w "$PLUGINS" ]]; then
    rm -rf "$DESTINATION"
    cp -R "$BUNDLE" "$DESTINATION"
  else
    sudo rm -rf "$DESTINATION"
    sudo cp -R "$BUNDLE" "$DESTINATION"
  fi
  echo "Installed $DESTINATION — restart Resolve to pick it up."
fi
