#!/bin/bash
# Builds Fotufilm, the desktop app: the engine library, the Resolve and Final Cut plug-ins it
# installs, and the Flutter editor around them.
#   flutter/build.sh               build build/flutter-host/Fotufilm.app
#   flutter/build.sh --no-plugins  leave the plug-ins out (the Plugins menu then says none are bundled)
# FLUTTER names the flutter tool (default: the one on PATH). An official build
# (FOTUFILM_SOURCE_BUILD=0) takes the Mac app's identity and release feed, so it replaces the
# installed app in place; a source build is an app of its own, with no feed.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
flutter_tool="${FLUTTER:-flutter}"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: the Flutter app builds on macOS only for now" >&2
  exit 1
fi
# Host links fail against some Command Line Tools SDKs; use Xcode's.
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cef/build-engine.sh
if [[ " $* " == *" --no-plugins "* ]]; then
  export FOTUFILM_PLUGINS_DIR=
else
  tools/build-editor-plugins.sh
  export FOTUFILM_PLUGINS_DIR="$PWD/build"
fi
export FOTUFILM_ENGINE_BUILD="$PWD/build/cef-engine"

tool_dir="$PWD/flutter"
(cd flutter && tool/prepare.sh)
# Dart names the generated plug-in registrant by its absolute path and offers no way to remap
# it, so the app compiles from a copy at a neutral path: no local path reaches the bundle
# (tools/audit-apple-bundle.sh).
stage="$(mktemp -d /tmp/fotufilm.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
rsync -a --exclude /build --exclude /.dart_tool --exclude /macos/Pods \
  --exclude /macos/Flutter/ephemeral --exclude /macos/Runner/Configs/Build.xcconfig \
  "$tool_dir/" "$stage/flutter/"
# What the Xcode project reads from beside it: the engine's C header and the app icon.
for shared in Sources/CFotufilmHost/include cef/mac/compile-icon.sh cef/mac/AppIcon.icon; do
  mkdir -p "$stage/$(dirname "$shared")"
  cp -R "$shared" "$stage/$shared"
done

version="$(sed -n 's/^MARKETING_VERSION=//p' version.env)"
build="$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' version.env)"
# The bundle states version.env's version as written: Flutter's build name pads "1.13" to
# "1.13.0", which would name the release and its feed differently. An official build also takes
# the Mac app's identity and feed. xcconfig reads `//` as a comment, so the URLs' slashes are
# kept apart by an empty $().
xcconfig_url() { printf '%s' "$1" | sed 's#//#/$()/#g'; }
{
  echo "FOTUFILM_MARKETING_VERSION = $version"
  if [[ "${FOTUFILM_SOURCE_BUILD:-1}" == 0 && "${FOTUFILM_USE_SOURCE_IDENTITY:-0}" != 1 ]]; then
    feed="${FOTUFILM_UPDATE_FEED_URL:-https://github.com/DhaliwalX/fotufilm-engine/releases/latest/download/Fotufilm-macOS-update.json}"
    list="${FOTUFILM_RELEASE_LIST_URL:-https://api.github.com/repos/DhaliwalX/fotufilm-engine/releases?per_page=100}"
    echo "FOTUFILM_BUNDLE_ID = com.muastudio.fotufilm"
    echo "FOTUFILM_UPDATE_FEED = $(xcconfig_url "$feed")"
    echo "FOTUFILM_RELEASE_LIST = $(xcconfig_url "$list")"
  fi
} > "$stage/flutter/macos/Runner/Configs/Build.xcconfig"
(
  cd "$stage/flutter"
  "$flutter_tool" --suppress-analytics build macos --release \
    --build-name "$version" --build-number "$build"
)

mkdir -p build/flutter-host
rm -rf build/flutter-host/Fotufilm.app
ditto "$stage/flutter/build/macos/Build/Products/Release/Fotufilm.app" build/flutter-host/Fotufilm.app
echo "Built build/flutter-host/Fotufilm.app ($version build $build)"
