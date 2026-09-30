#!/bin/bash
# Builds the libjpeg the AppImage carries: libjpeg-turbo 3 with the libjpeg 8 interface, so the
# engine, LibRaw and libheif find the libjpeg.so.8 they link, and so does the system's libtiff.
# Distributions that build libtiff against libjpeg-turbo 3 call its 12-bit functions
# (jpeg12_*), which the libjpeg-turbo 2 of an older build host lacks; the loader would bind their
# libtiff to that older copy and refuse to start the app. Prints the library's path; reuses a
# finished build.
#   cef/build-libjpeg-turbo-linux.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

VERSION=3.2.0
DIGEST=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
BUILD="$PWD/build/libjpeg-turbo"
SOURCE="$BUILD/libjpeg-turbo-$VERSION"
LIBRARY="$BUILD/install/lib/libjpeg.so.8"
if [[ -f "$LIBRARY" && -f "$BUILD/install/VERSION" && "$(<"$BUILD/install/VERSION")" == "$VERSION" ]]; then
  echo "$LIBRARY"
  exit 0
fi

mkdir -p "$BUILD"
ARCHIVE="$BUILD/libjpeg-turbo-$VERSION.tar.gz"
[[ -f "$ARCHIVE" ]] || curl -sfL --retry 3 -o "$ARCHIVE" \
  "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$VERSION/libjpeg-turbo-$VERSION.tar.gz"
if [[ "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" != "$DIGEST" ]]; then
  echo "libjpeg-turbo $VERSION checksum mismatch" >&2
  rm -f "$ARCHIVE"
  exit 1
fi
rm -rf "$SOURCE" "$BUILD/cmake" "$BUILD/install"
tar -xzf "$ARCHIVE" -C "$BUILD"

# Only the shared libjpeg; the SIMD code needs nasm or yasm.
cmake -S "$SOURCE" -B "$BUILD/cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD/install" -DCMAKE_INSTALL_LIBDIR=lib \
  -DWITH_JPEG8=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
  -DREQUIRE_SIMD=ON >/dev/null
cmake --build "$BUILD/cmake" --parallel "$(nproc)" >/dev/null
cmake --install "$BUILD/cmake" >/dev/null
cp "$SOURCE/LICENSE.md" "$SOURCE/README.ijg" "$BUILD/install/"
echo "$VERSION" > "$BUILD/install/VERSION"
echo "$LIBRARY"
