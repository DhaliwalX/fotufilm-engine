#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

# The wrapper cannot be called Fotufilm: the Mac app is, and both want /Applications. The name is
# what Finder shows for an application, so it has to say which one this is.
APP="build/finalcut/Fotufilm for Final Cut Pro.app"
PLUGIN="$APP/Contents/PlugIns/Fotufilm.pluginkit"
DSYM="build/finalcut/Fotufilm.pluginkit.dSYM"
MOTION_TEMPLATE_SOURCE="finalcut/MotionTemplate/Fotufilm.moef"

# Final Cut loads FxPlug filters through a Motion effect template. Validate the two failure modes
# that are otherwise discovered only after launch: a dynamic channel tree crashes its serializer,
# and an unpublished tree produces an empty inspector.
tools/validate-fcp-template.py "$MOTION_TEMPLATE_SOURCE"

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

TEST=0
[[ " $* " == *" --test "* ]] && TEST=1
INSTALL=0
[[ " $* " == *" --install "* ]] && INSTALL=1

# --- the FxPlug SDK -----------------------------------------------------------------------------
#
# FxPlug ships in two pieces, and they are not the same pieces. The sparse SDK under
# /Library/Developer/SDKs/FxPlug.sdk carries the headers and .tbd stubs to compile and link
# against; /Library/Developer/Frameworks carries the real FxPlug and PluginManager frameworks,
# which the bundle has to embed because their install names are @rpath-relative. It is a free
# download from Apple's developer site and is not vendored here, because it is Apple's to
# distribute. Both halves are needed and neither can be worked around.

FXPLUG_SDK="${FXPLUG_SDK:-/Library/Developer/SDKs/FxPlug.sdk}"
FXPLUG_FRAMEWORKS="${FXPLUG_FRAMEWORKS:-/Library/Developer/Frameworks}"

# `--test` runs the harness, which stands the plugin up against a stand-in for the SDK; that path
# deliberately does not need the SDK. `--test` alone stops there, so the SDK checks below are
# skipped for it — but `--test --install` runs the harness *and then* builds and installs, and
# needs both halves of the SDK. Silently skipping the harness because an install was also asked
# for is what this used to do, and it is exactly backwards: the run that ships is the run that
# most needs checking.
BUILD_SDK=1
(( TEST )) && (( ! INSTALL )) && BUILD_SDK=0

if (( BUILD_SDK )) && [[ ! -d "$FXPLUG_SDK" ]]; then
  cat >&2 <<EOF
error: the FxPlug SDK is not installed.

  Expected: $FXPLUG_SDK

  It is a free download from https://developer.apple.com/download/all/ (search "FxPlug"). Install
  it, or point FXPLUG_SDK at it if it lives somewhere else.
EOF
  exit 1
fi

FXPLUG_HEADERS="$FXPLUG_SDK/Library/Frameworks"

if (( BUILD_SDK )); then
  for framework in FxPlug PluginManager; do
    if [[ ! -d "$FXPLUG_FRAMEWORKS/$framework.framework" ]]; then
      echo "error: $FXPLUG_FRAMEWORKS/$framework.framework is missing; reinstall the FxPlug SDK." >&2
      exit 1
    fi
  done
fi

# --- the harness -------------------------------------------------------------------------------
#
# The engine-facing half of the plugin, driven through real renders by a stand-in host. It needs no
# FxPlug SDK, which is the point: the half that can be checked anywhere is checked anywhere.
if (( TEST )); then
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64)  KERNEL_PLATFORM="macos" ;;
    x86_64) KERNEL_PLATFORM="macos-intel" ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
  esac
  KERNELS="build/halide-$KERNEL_PLATFORM"
  OBJ="build/finalcut/obj-$ARCH"
  TARGET="$ARCH-apple-macos$DEPLOYMENT"
  mkdir -p "$OBJ"

  tools/generate-halide-aot.sh "$KERNEL_PLATFORM" "$KERNELS"

  xcrun clang++ -std=c++17 -O2 -c -isysroot "$SDK" -target "$TARGET" \
    -DFOTUFILM_HALIDE_IOS_AOT=1 -I"$KERNELS" -ISources/FotufilmHalide/include \
    Sources/FotufilmHalide/FotufilmHalideIOS.cpp -o "$OBJ/FotufilmHalideIOS.o"
  xcrun clang++ -std=c++17 -O2 -c -isysroot "$SDK" -target "$TARGET" \
    -Iresolve resolve/WorkingSpace.cpp -o "$OBJ/WorkingSpace.o"
  for source in FotufilmEffect tests/HostHarness; do
    xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wno-nullability-completeness -c \
      -isysroot "$SDK" -target "$TARGET" -DFOTUFILM_FXPLUG_STUB=1 \
      -Ifinalcut/tests -Iresolve -Ifinalcut -Iresolve/tests \
      "finalcut/$source.mm" -o "$OBJ/$(basename "$source").o"
  done
  # The parity frame is shared with the OFX harness, so that "the same picture" means the same
  # pixels rather than two descriptions of one.
  xcrun clang++ -std=c++17 -O2 -c -isysroot "$SDK" -target "$TARGET" \
    -Iresolve/tests resolve/tests/ParityFrame.cpp -o "$OBJ/ParityFrame.o"
  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -sdk "$SDK" -target "$TARGET" -swift-version 5 -O -parse-as-library \
    -D FOTUFILM_LICENSE_TESTING \
    Sources/FotufilmLicense/*.swift \
    "$FOTUFILM_CORE_SOURCE_DIR"/*.swift Sources/FotufilmMetal/*.swift \
    "$FOTUFILM_PACK_KEY_SOURCE" resolve/FotufilmBridge.swift \
    "$OBJ/FotufilmHalideIOS.o" "$OBJ/WorkingSpace.o" \
    "$OBJ/FotufilmEffect.o" "$OBJ/HostHarness.o" "$OBJ/ParityFrame.o" \
    "$KERNELS"/*.a \
    -Xlinker -lc++ \
    -framework Metal -framework Foundation -framework AppKit \
    -framework Accelerate -framework CoreMedia -framework CoreVideo -framework IOSurface \
    -o "build/finalcut/host-harness"
  # The harness is the gate, not a footnote: `set -e` stops here if it fails, so nothing that
  # follows — including an install — can happen over a plugin that did not pass.
  env -u FOTUFILM_REALTIME \
    FOTUFILM_LICENSE_TEST_BYPASS=1 \
    FOTUFILM_RESOURCES="$PWD/Sources/FotufilmCore/Resources" \
    FOTUFILM_STOCKS="$PWD/Sources/FotufilmCore/Stocks" \
    "build/finalcut/host-harness"

  # The harness object files are compiled against the stub and would be the wrong ones to ship.
  # The per-architecture loop below wipes the directory before it builds, so they cannot survive
  # into a bundle; this is only what makes that guarantee legible.
  rm -rf "build/finalcut/obj-$ARCH"

  (( BUILD_SDK )) || exit 0
  echo "--- the harness passed; building against the FxPlug SDK ---"
fi

rm -rf "$APP" "$DSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$PLUGIN/Contents/MacOS" "$PLUGIN/Contents/Resources"

SLICES=()
WRAPPER_SLICES=()
for ARCH in "${ARCHS[@]}"; do
  TARGET="$ARCH-apple-macos$DEPLOYMENT"
  OBJ="build/finalcut/obj-$ARCH"
  case "$ARCH" in
    arm64)  KERNEL_PLATFORM="macos" ;;
    x86_64) KERNEL_PLATFORM="macos-intel" ;;
    *) echo "unsupported architecture: $ARCH" >&2; exit 2 ;;
  esac
  KERNELS="build/halide-$KERNEL_PLATFORM"

  echo "--- $ARCH ---"
  tools/generate-halide-aot.sh "$KERNEL_PLATFORM" "$KERNELS"

  rm -rf "$OBJ"; mkdir -p "$OBJ"

  # The engine's Halide shim, ahead-of-time. Nothing that ships carries a compiler.
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

  # The colour-space maths, shared verbatim with the OFX plugin. One definition of what a
  # timeline's encoding is, so the two hosts cannot disagree about it.
  xcrun clang++ -std=c++17 -O2 -gline-tables-only -flto=thin \
    -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
    -fmacro-prefix-map="$PWD"=Fotufilm \
    -ffunction-sections -fdata-sections -c \
    -isysroot "$SDK" -target "$TARGET" \
    -Iresolve resolve/WorkingSpace.cpp \
    -o "$OBJ/WorkingSpace.o"

  xcrun clang++ -std=c++17 -fobjc-arc -O2 -gline-tables-only \
    -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
    -fmacro-prefix-map="$PWD"=Fotufilm \
    -ffunction-sections -fdata-sections -c \
    -isysroot "$SDK" -target "$TARGET" \
    -F"$FXPLUG_HEADERS" \
    -Iresolve -Ifinalcut \
    finalcut/FotufilmEffect.mm \
    -o "$OBJ/FotufilmEffect.o"

  xcrun clang -fobjc-arc -O2 -c \
    -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
    -fmacro-prefix-map="$PWD"=Fotufilm \
    -isysroot "$SDK" -target "$TARGET" \
    -F"$FXPLUG_HEADERS" \
    finalcut/PlugInMain.m -o "$OBJ/PlugInMain.o"

  xcrun clang -fobjc-arc -O2 -c \
    -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
    -fmacro-prefix-map="$PWD"=Fotufilm \
    -isysroot "$SDK" -target "$TARGET" \
    finalcut/WrapperMain.m -o "$OBJ/WrapperMain.o"

  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -sdk "$SDK" \
    -target "$TARGET" \
    -swift-version 5 \
    -O -whole-module-optimization -g -parse-as-library \
    -file-prefix-map "$PWD=Fotufilm" \
    -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
    -module-name FotufilmFxPlug -emit-object \
    Sources/FotufilmLicense/*.swift \
    "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
    Sources/FotufilmMetal/*.swift \
    "$FOTUFILM_PACK_KEY_SOURCE" \
    resolve/FotufilmBridge.swift \
    -o "$OBJ/FotufilmSwift.o"

  # The extension. Halide's runtime is linked private for the same reason the OFX bundle does it:
  # a second Halide in the same process binds the wrong runtime and aborts mid-frame. The pro apps
  # run this out of process so the collision is unlikely here, but the cost of keeping it private
  # is nothing and the failure it prevents is a crash on the first frame.
  xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
    -sdk "$SDK" \
    -target "$TARGET" \
    "$OBJ/FotufilmSwift.o" \
    "$OBJ/FotufilmHalideIOS.o" "$OBJ/WorkingSpace.o" \
    "$OBJ/FotufilmEffect.o" "$OBJ/PlugInMain.o" \
    "$KERNELS"/*.a \
    -Xlinker -lc++ \
    -Xlinker -dead_strip \
    -F"$FXPLUG_HEADERS" \
    -framework FxPlug -framework PluginManager \
    -framework Metal -framework Foundation -framework AppKit \
    -framework Accelerate -framework CoreMedia -framework CoreVideo -framework IOSurface \
    -Xlinker -unexported_symbols_list -Xlinker resolve/private-symbols.txt \
    -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
    -o "$OBJ/Fotufilm.pluginkit.bin"

  tools/verify-apple-aot.sh "$OBJ/Fotufilm.pluginkit.bin"

  xcrun clang -fobjc-arc -O2 \
    -isysroot "$SDK" -target "$TARGET" \
    "$OBJ/WrapperMain.o" -framework AppKit \
    -o "$OBJ/Fotufilm.app.bin"

  SLICES+=("$OBJ/Fotufilm.pluginkit.bin")
  WRAPPER_SLICES+=("$OBJ/Fotufilm.app.bin")
done

if (( ${#SLICES[@]} > 1 )); then
  lipo -create "${SLICES[@]}" -output "$PLUGIN/Contents/MacOS/Fotufilm"
  lipo -create "${WRAPPER_SLICES[@]}" -output "$APP/Contents/MacOS/Fotufilm"
else
  cp "${SLICES[0]}" "$PLUGIN/Contents/MacOS/Fotufilm"
  cp "${WRAPPER_SLICES[0]}" "$APP/Contents/MacOS/Fotufilm"
fi

xcrun dsymutil "$PLUGIN/Contents/MacOS/Fotufilm" -o "$DSYM"
xcrun strip -S -x -T -N "$PLUGIN/Contents/MacOS/Fotufilm"
xcrun strip -S -x -N "$APP/Contents/MacOS/Fotufilm"

cp finalcut/Info-PlugIn.plist "$PLUGIN/Contents/Info.plist"
cp finalcut/Info-App.plist "$APP/Contents/Info.plist"

# The wrapper carries the template so every install route can place the same checked file in the
# current user's Motion Templates library. Final Cut requires both preview sizes even though they
# are only browser artwork.
MOTION_TEMPLATE="$APP/Contents/Resources/MotionTemplate"
mkdir -p "$MOTION_TEMPLATE"
cp "$MOTION_TEMPLATE_SOURCE" "$MOTION_TEMPLATE/Fotufilm.moef"
swift tools/generate-example-image.swift "$OBJ/example.png"
sips --cropToHeightWidth 1152 2048 "$OBJ/example.png" \
  --out "$MOTION_TEMPLATE/large.png" >/dev/null
sips --resampleHeightWidth 360 640 "$MOTION_TEMPLATE/large.png" >/dev/null
sips --resampleHeightWidth 108 192 "$MOTION_TEMPLATE/large.png" \
  --out "$MOTION_TEMPLATE/small.png" >/dev/null
tools/validate-fcp-template.py "$MOTION_TEMPLATE/Fotufilm.moef" --require-previews

# The wrapper is the one part of this a user actually looks at — it is what tells them the plug-in
# is installed — so it gets the app's icon rather than the generic placeholder.
if [[ -d macos/AppIcon.icon ]]; then
  if ! xcrun actool macos/AppIcon.icon \
      --compile "$APP/Contents/Resources" \
      --platform macosx --minimum-deployment-target "$DEPLOYMENT" \
      --app-icon AppIcon \
      --output-partial-info-plist "build/finalcut/icon-partial.plist" >/dev/null 2>&1; then
    echo "warning: actool could not compile macos/AppIcon.icon (Xcode 26 required); the wrapper will use the generic icon." >&2
  fi
fi

# An Info.plist that names an icon the bundle does not carry is worse than one that names none:
# Launch Services caches the lookup failure, and `--strict` codesign verification on some systems
# reads a missing named resource as a broken bundle. So the keys stay only if actool actually
# produced something for them to point at.
if [[ ! -f "$APP/Contents/Resources/Assets.car" && ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  for key in CFBundleIconName CFBundleIconFile; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
  done
  echo "warning: no compiled app icon; the wrapper's Info.plist no longer claims one." >&2
fi

# One version line for the whole product. version.env drives the Xcode targets, and this bundle is
# assembled by hand; reading it back out is what keeps the two from drifting. The Mac app compares
# these numbers against the installed copy to decide whether it is out of date, so the stamp has to
# happen before the signature seals over it.
source version.env
[[ -n "$MARKETING_VERSION" && -n "$CURRENT_PROJECT_VERSION" ]] || {
  echo "error: version.env must define MARKETING_VERSION and CURRENT_PROJECT_VERSION" >&2
  exit 1
}
PROJECT_VERSION="$CURRENT_PROJECT_VERSION"
for plist in "$PLUGIN/Contents/Info.plist" "$APP/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PROJECT_VERSION" "$plist"
done

# The engine's own resources, in the extension bundle rather than the app's. `Bundle.main` inside
# an extension is the extension, and the extension is the process that develops.
tools/copy-shipping-resources.sh "$PLUGIN/Contents/Resources"

# Into the extension rather than the app: the linker was given @loader_path/../Frameworks, and
# @loader_path is the extension's own executable. Headers are excluded — they are the SDK's, they
# are not code, and shipping them only widens what has to be signed.
mkdir -p "$PLUGIN/Contents/Frameworks"
for framework in FxPlug PluginManager; do
  rsync --archive --links --whole-file --no-owner --no-group \
    --exclude='Headers' --exclude='Modules' \
    "$FXPLUG_FRAMEWORKS/$framework.framework/" \
    "$PLUGIN/Contents/Frameworks/$framework.framework/"
done

# Signing runs inside out: a bundle's seal covers everything under it, so anything re-signed after
# its container breaks the container's seal. macOS will not load an extension whose signature does
# not verify, and that failure is silent — the effect simply never appears in the browser.
sign() {
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$1"
  else
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$1"
  fi
}
for framework in "$PLUGIN/Contents/Frameworks/"*.framework; do sign "$framework"; done
sign "$PLUGIN"
sign "$APP"
codesign --verify --deep --strict "$APP"
tools/audit-apple-bundle.sh "$APP"

echo "Built $APP ($(lipo -archs "$PLUGIN/Contents/MacOS/Fotufilm"))"

STRAY="$(otool -L "$PLUGIN/Contents/MacOS/Fotufilm" \
  | grep $'^\t' | awk '{print $1}' | sort -u \
  | grep -v '^/usr/lib/' | grep -v '^/System/Library/' \
  | grep -v '^@rpath/' || true)"
if [[ -n "$STRAY" ]]; then
  echo "error: the extension depends on libraries the bundle does not carry:" >&2
  echo "$STRAY" | sed 's/^/  /' >&2
  exit 1
fi

if [[ " $* " == *" --install "* ]]; then
  DESTINATION="/Applications/Fotufilm for Final Cut Pro.app"
  if [[ -w /Applications ]]; then
    rm -rf "$DESTINATION"
    cp -R "$APP" "$DESTINATION"
  else
    sudo rm -rf "$DESTINATION"
    sudo cp -R "$APP" "$DESTINATION"
  fi
  # PlugInKit registers an extension when it sees the application that carries it. Launching it
  # once is the registration; nothing else in the app does anything.
  # `--register` for the same reason the Mac app's installer passes it: this script is the thing
  # reporting to whoever ran it, and a wrapper that stops to say its own piece leaves `open -W`
  # waiting on a dialog nobody is watching.
  open -W "$DESTINATION" --args --register
  TEMPLATE_DESTINATION="$HOME/Movies/Motion Templates.localized/Effects.localized/Fotufilm.localized/Fotufilm.localized"
  mkdir -p "$(dirname "$TEMPLATE_DESTINATION")"
  rm -rf "$TEMPLATE_DESTINATION"
  /usr/bin/ditto "$DESTINATION/Contents/Resources/MotionTemplate" "$TEMPLATE_DESTINATION"
  if ! /usr/bin/pluginkit -e use -i com.fotufilm.fxplug; then
    echo "warning: PlugInKit has not enabled the extension yet; registration may still be pending." >&2
  fi
  # `-p FxPlug` is the protocol the Info.plist declares, and the only one this answers. Asking for
  # the generic view-provider extension point instead finds nothing and says so, which reads as a
  # failed install when the install worked.
  pluginkit -m -p FxPlug -v | grep -i fotufilm || \
    echo "warning: PlugInKit has not registered the extension yet." >&2
  echo "Installed $DESTINATION and $TEMPLATE_DESTINATION — restart Final Cut Pro to pick them up."
fi
