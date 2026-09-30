#!/bin/bash
# Builds Fotufilm Desktop: fetches the pinned CEF, builds the engine library, the Resolve and Final
# Cut plug-ins it installs, and the web editor, then the host.
#   cef/build.sh               build build/cef-host/Release/Fotufilm.app
#   cef/build.sh --run         build, then open the bridge diagnostics page
#   cef/build.sh --no-plugins  leave the plug-ins out (the Plugins menu then says none are bundled)
# On Linux it builds build/cef-host/Release/fotufilm and the engine's CUDA and Vulkan kernels
# (HALIDE_ROOT, cef/build-engine-linux.sh); cef/package-appimage.sh then packs the AppImage.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

cef_root="$(cef/fetch-cef.sh)"
(cd web && npm ci --silent && npm run build --silent)
if [[ "$(uname -s)" == Darwin ]]; then
  # Host links fail against some Command Line Tools SDKs; use Xcode's.
  export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
  extra=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
  cef/build-engine.sh
  # Named on every configure: the cache would otherwise keep the last run's choice.
  if [[ " $* " == *" --no-plugins "* ]]; then
    extra+=(-DFOTUFILM_PLUGINS_DIR=)
  else
    tools/build-editor-plugins.sh
    extra+=(-DFOTUFILM_PLUGINS_DIR="$PWD/build")
  fi
elif [[ "$(uname -s)" == Linux ]]; then
  cef/build-engine-linux.sh
fi
# An official build (FOTUFILM_SOURCE_BUILD=0) is the Mac app: its identity and its release feed.
if [[ "${FOTUFILM_SOURCE_BUILD:-1}" == 0 && "${FOTUFILM_USE_SOURCE_IDENTITY:-0}" != 1 ]]; then
  extra+=(-DFOTUFILM_BUNDLE_ID=com.muastudio.fotufilm
          -DFOTUFILM_UPDATE_FEED="${FOTUFILM_UPDATE_FEED_URL:-https://github.com/DhaliwalX/fotufilm-engine/releases/latest/download/Fotufilm-macOS-update.json}")
else
  extra+=(-DFOTUFILM_BUNDLE_ID=com.muastudio.fotufilm.source -DFOTUFILM_UPDATE_FEED=)
fi
cmake -S cef -B build/cef-host -G Ninja -DCEF_ROOT="$cef_root" "${extra[@]}"
cmake --build build/cef-host

if [[ " $* " == *" --run "* ]]; then
  "build/cef-host/Release/Fotufilm.app/Contents/MacOS/Fotufilm" \
    --fotufilm-diagnostics
fi
