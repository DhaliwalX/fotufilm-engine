#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
source tools/desktop-build-config.sh

# The Lensfun database is CC-BY-SA: bundling it would impose attribution and share-alike
# obligations nothing here discharges. tools/import-lensfun.py exists for local experiments;
# its output must never become a tracked resource without a deliberate licensing decision
# (see LICENSING.md).
if git ls-files -- '*lens-profiles.json' | grep -q .; then
  echo "error: a lens-profiles.json is tracked; the Lensfun database is CC-BY-SA and must not ship." >&2
  exit 1
fi

# `--test` runs the OFX plug-in's own host harness as part of this build instead of beside it.
# The harness is compiled from the same objects the bundle is, so a separate CI step that ran
# `resolve/build.sh --test` before this script built that bundle twice: once to check it and once
# to ship it. Forwarding the flag is what makes one run of the compiler do both jobs, and it runs
# before the app is compiled, so a failed check still stops the build early.
OFX_TEST=""
[[ " $* " == *" --test "* ]] && OFX_TEST="--test"

APP="build/macos/Fotufilm.app"
OBJ="build/macos/obj"
EXECUTABLE="$APP/Contents/MacOS/Fotufilm"
DSYM="build/macos/Fotufilm.app.dSYM"

HALIDE_PREFIX="${HALIDE_ROOT:-}"
if [[ -z "$HALIDE_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  HALIDE_PREFIX="$(brew --prefix halide 2>/dev/null || true)"
fi
[[ -n "$HALIDE_PREFIX" && -f "$HALIDE_PREFIX/include/Halide.h" ]] || {
  echo "Halide is required (brew install halide, or set HALIDE_ROOT)." >&2
  exit 1
}

rm -rf "$APP" "$OBJ" "$DSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

KERNELS="build/halide-macos"
# The copy inside the app is the same signed, stripped bundle distributed on its own. The Mac app
# installs this resource into the user's OFX directory on request.
resolve/build.sh ${OFX_TEST:+$OFX_TEST}

# The Final Cut plug-in needs Apple's FxPlug SDK, which is a separate download and is not vendored
# here. A machine without it builds an app that says so — FxPlugInstaller.bundledURL comes back nil
# and the menu item is disabled — rather than failing a build that has nothing to do with Final Cut.
FXPLUG_APP="build/finalcut/Fotufilm for Final Cut Pro.app"
if [[ -d "${FXPLUG_SDK:-/Library/Developer/SDKs/FxPlug.sdk}" ]]; then
  finalcut/build.sh
else
  rm -rf "$FXPLUG_APP"
  echo "note: the FxPlug SDK is not installed; this build carries no Final Cut Pro plug-in." >&2
fi

tools/generate-halide-aot.sh macos "$KERNELS"

xcrun clang++ -std=c++17 -O2 -gline-tables-only -flto=thin \
  -fvisibility=hidden -fvisibility-inlines-hidden \
  -ffile-prefix-map="$PWD"=Fotufilm -fdebug-prefix-map="$PWD"=Fotufilm \
  -fmacro-prefix-map="$PWD"=Fotufilm \
  -ffunction-sections -fdata-sections -c \
  -isysroot "$SDK" -target arm64-apple-macos14.0 \
  -DFOTUFILM_HALIDE_IOS_AOT=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  -o "$OBJ/FotufilmHalideIOS.o"

# desktop/FotufilmApp is the session itself — canvas, columns, sheets — written once against the
# platform shim and compiled here as AppKit and in ios/build.sh as UIKit. Nothing in it imports
# SwiftUI, on either side.
SHARED_SOURCES=()
for source in shared/FotufilmApp/*.swift; do
  [[ "$source" == shared/FotufilmApp/FilmPackKeyMaterial.swift ]] || SHARED_SOURCES+=("$source")
done

xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -swift-version 5 \
  -O -whole-module-optimization -g -parse-as-library \
  -file-prefix-map "$PWD=Fotufilm" \
    -file-prefix-map "$FOTUFILM_CORE_SOURCE_DIR=Fotufilm/Sources/FotufilmCore" \
  -module-name Fotufilm -emit-object \
  Sources/FotufilmUpdate/*.swift \
  "$FOTUFILM_CORE_SOURCE_DIR"/*.swift \
  Sources/FotufilmMetal/*.swift \
  Sources/FotufilmImaging/*.swift \
  Sources/FotufilmStockMatch/*.swift \
  Sources/FotufilmEditModel/*.swift \
  "${SHARED_SOURCES[@]}" "$FOTUFILM_PACK_KEY_SOURCE" \
  desktop/FotufilmApp/*.swift \
  macos/FotufilmApp/*.swift \
  -o "$OBJ/FotufilmSwift.o"

xcrun swiftc ${SOURCE_BUILD_FLAGS[@]+"${SOURCE_BUILD_FLAGS[@]}"} \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -emit-executable \
  "$OBJ/FotufilmSwift.o" \
  "$OBJ/FotufilmHalideIOS.o" \
  "$KERNELS"/*.a \
  -Xlinker -lc++ \
  -Xlinker -dead_strip -Xlinker -no_exported_symbols \
  -framework Metal -framework MetalKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreImage -framework Accelerate -framework QuartzCore \
  -framework ImageIO \
  -o "$EXECUTABLE"

# Refuse to package a release app if its generated Halide schedules were dropped or replaced by a
# dynamically linked JIT runtime.
tools/verify-apple-aot.sh "$EXECUTABLE" --no-exports

# Keep symbolication material beside the bundle, never inside it. The shipped executable retains
# neither debug/local symbols nor Swift symbol-table names.
xcrun dsymutil "$EXECUTABLE" -o "$DSYM"
xcrun strip -S -x -T -N "$EXECUTABLE"

EXPORTED="$(nm -gU "$EXECUTABLE" 2>/dev/null | awk '{print $3}' | sort -u || true)"
if [[ -n "$EXPORTED" ]]; then
  echo "error: the app executable exports application symbols:" >&2
  echo "$EXPORTED" | sed 's/^/  /' >&2
  exit 1
fi

cp macos/FotufilmApp/Info.plist "$APP/Contents/Info.plist"
if [[ "$FOTUFILM_SOURCE_BUILD" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.muastudio.fotufilm.source" "$APP/Contents/Info.plist"
  for key in FotufilmUpdateFeedURL; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist"
  done
fi


if [[ -n "${FOTUFILM_UPDATE_FEED_URL:-}" ]]; then
  if /usr/libexec/PlistBuddy -c "Print :FotufilmUpdateFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c \
      "Set :FotufilmUpdateFeedURL $FOTUFILM_UPDATE_FEED_URL" "$APP/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c \
      "Add :FotufilmUpdateFeedURL string $FOTUFILM_UPDATE_FEED_URL" "$APP/Contents/Info.plist"
  fi
fi

# One version line for the product. version.env drives the Xcode targets, and this bundle is
# assembled by hand, so the two drifted: the Mac shipped 1.0/1 while the phone was on 1.1/5. Read
# them back out of version.env rather than keeping a second copy anyone has to remember to bump.
source version.env
[[ -n "$MARKETING_VERSION" && -n "$CURRENT_PROJECT_VERSION" ]] || {
  echo "error: version.env must define MARKETING_VERSION and CURRENT_PROJECT_VERSION" >&2
  exit 1
}
PROJECT_VERSION="$CURRENT_PROJECT_VERSION"
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleVersion $PROJECT_VERSION" "$APP/Contents/Info.plist"
swift tools/generate-example-image.swift "$APP/Contents/Resources/sample.png"
# Bundle the outlined wordmark without a font dependency.
cp macos/Resources/FOTUFILM.svg \
  "$APP/Contents/Resources/FOTUFILM.svg"
tools/copy-shipping-resources.sh "$APP/Contents/Resources" --camera-profiles
cp -R build/resolve/Fotufilm.ofx.bundle "$APP/Contents/Resources/"
# ditto rather than cp: the wrapper carries its own signed extension and two frameworks, and the
# copy has to leave those seals intact — a resigned nested bundle is one macOS will not load.
if [[ -d "$FXPLUG_APP" ]]; then
  ditto "$FXPLUG_APP" "$APP/Contents/Resources/$(basename "$FXPLUG_APP")"
fi

if [[ -d macos/AppIcon.icon ]]; then
  if ! xcrun actool macos/AppIcon.icon \
      --compile "$APP/Contents/Resources" \
      --platform macosx --minimum-deployment-target 14.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "$OBJ/icon-partial.plist" >/dev/null 2>&1; then
    echo "warning: actool could not compile macos/AppIcon.icon (Xcode 26 required); the app will use the generic icon." >&2
  fi
fi

tools/build-handwritten-metallib.sh macosx "$APP/Contents/Resources/HandwrittenFotufilm.metallib"
tools/audit-apple-bundle.sh "$APP"

# Sign the app, so the Keychain recognises it from one build to the next.
#
# macOS binds a keychain item's "Always Allow" to the *designated requirement* of the application
# that asked. For an ad-hoc signature that requirement is the binary's own hash — `codesign -d -r-`
# prints `designated => cdhash H"…"` — so every rebuild is a different application to the Keychain,
# and the panel comes back however many times it has been dismissed. StockPacks keeps this device's
# film-sealing key there, so that is one panel per launch after every build. A real identity has a
# requirement of identifier plus team, which does not move when the binary does.
#
# Ad-hoc stays the default, because a machine without an identity still has to build; set
# FOTUFILM_CODESIGN_IDENTITY to a signing identity to stop the prompts. The nested plug-in bundles
# signed themselves already, with the same variable, and this seals over them.
IDENTITY="${FOTUFILM_CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo "Built $APP ($MARKETING_VERSION build $PROJECT_VERSION)"

if [[ "${1:-}" == "--launch" ]]; then
  open "$APP" --args --demo
fi
