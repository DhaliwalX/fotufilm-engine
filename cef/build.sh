#!/bin/bash
# Builds Fotufilm Desktop: fetches the pinned CEF, builds the engine library and the web editor,
# then the host.
#   cef/build.sh           build build/cef-host/Release/Fotufilm Desktop.app
#   cef/build.sh --run     build, then open the bridge diagnostics page
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

cef_root="$(cef/fetch-cef.sh)"
(cd web && npm ci --silent && npm run build --silent)
if [[ "$(uname -s)" == Darwin ]]; then
  # Host links fail against some Command Line Tools SDKs; use Xcode's.
  export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
  extra=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
  cef/build-engine.sh
fi
cmake -S cef -B build/cef-host -G Ninja -DCEF_ROOT="$cef_root" "${extra[@]}"
cmake --build build/cef-host

if [[ " $* " == *" --run "* ]]; then
  "build/cef-host/Release/Fotufilm Desktop.app/Contents/MacOS/Fotufilm Desktop" \
    --fotufilm-diagnostics
fi
