#!/bin/bash
# Builds Fotufilm for Android: the engine library (tools/build-android-engine.sh) and the Flutter
# editor around it.
#   flutter/build-android.sh              build build/flutter-host/Fotufilm.apk
#   flutter/build-android.sh --appbundle  build build/flutter-host/Fotufilm.aab, for Google Play
# FLUTTER names the flutter tool (default: the one on PATH). An official build
# (FOTUFILM_SOURCE_BUILD=0) takes the Android app's identity, so it replaces the installed app in
# place; a source build is an app of its own. FOTUFILM_ANDROID_KEYSTORE, with
# FOTUFILM_ANDROID_KEYSTORE_PASSWORD, FOTUFILM_ANDROID_KEY_ALIAS and FOTUFILM_ANDROID_KEY_PASSWORD,
# signs it for release; without one it is signed with the debug keys.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
flutter_tool="${FLUTTER:-flutter}"
artifact=apk
[[ " $* " == *" --appbundle "* ]] && artifact=appbundle

# The codecs and FFmpeg are built once, into FOTUFILM_ANDROID_DEPS.
[[ -f "${FOTUFILM_ANDROID_DEPS:-build/android-deps}/arm64/lib/libjpeg.a" ]] || tools/build-android-codecs.sh
tools/build-android-engine.sh
export FOTUFILM_ANDROID_ENGINE="$PWD/flutter/build/android-engine"
[[ -z "${FOTUFILM_ANDROID_KEYSTORE:-}" ]] ||
  FOTUFILM_ANDROID_KEYSTORE="$(cd "$(dirname "$FOTUFILM_ANDROID_KEYSTORE")" && pwd -P)/$(basename "$FOTUFILM_ANDROID_KEYSTORE")"

tool_dir="$PWD/flutter"
(cd flutter && tool/prepare.sh)
# As flutter/build.sh does: the app compiles from a copy at a neutral path, so no local path
# reaches the package.
stage="$(mktemp -d /tmp/fotufilm.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
rsync -a --exclude /build --exclude /.dart_tool --exclude /android/.gradle \
  --exclude /android/local.properties --exclude /android/app/.cxx "$tool_dir/" "$stage/flutter/"

version="$(sed -n 's/^MARKETING_VERSION=//p' version.env)"
build="$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' version.env)"
if [[ "${FOTUFILM_SOURCE_BUILD:-1}" == 0 && "${FOTUFILM_USE_SOURCE_IDENTITY:-0}" != 1 ]]; then
  export FOTUFILM_ANDROID_APPLICATION_ID=com.muastudio.fotufilm
fi
(
  cd "$stage/flutter"
  "$flutter_tool" --suppress-analytics build "$artifact" --release --target-platform android-arm64 \
    --build-name "$version" --build-number "$build"
)

mkdir -p build/flutter-host
if [[ "$artifact" == apk ]]; then
  output=build/flutter-host/Fotufilm.apk
  cp "$stage/flutter/build/app/outputs/flutter-apk/app-release.apk" "$output"
  # No local path in anything the package carries.
  # Each entry under its own number: resource names can differ only in case, which a Mac's
  # filesystem folds together.
  python3 -c '
import sys, zipfile
from pathlib import Path
out = Path(sys.argv[2])
out.mkdir()
with zipfile.ZipFile(sys.argv[1]) as package:
    for number, entry in enumerate(package.infolist()):
        if not entry.is_dir():
            (out / str(number)).write_bytes(package.read(entry))' "$output" "$stage/package"
  python3 tools/audit-bundle-paths.py "$stage/package"
  deps="$(cd "${FOTUFILM_ANDROID_DEPS:-build/android-deps}" && pwd -P)"
  folders=(-e "$PWD/" -e "$deps/" -e "$HOME/")
  [[ -z "${ANDROID_HOME:-}" ]] || folders+=(-e "$ANDROID_HOME/")
  [[ -z "${HALIDE_ROOT:-}" ]] || folders+=(-e "$(dirname "$HALIDE_ROOT")/")
  if grep -rlaF "${folders[@]}" "$stage/package"; then
    echo "error: a build folder is named in the files above" >&2
    exit 1
  fi
else
  output=build/flutter-host/Fotufilm.aab
  cp "$stage/flutter/build/app/outputs/bundle/release/app-release.aab" "$output"
fi
echo "Built $output (${FOTUFILM_ANDROID_APPLICATION_ID:-com.muastudio.fotufilm.flutter} $version build $build)"
