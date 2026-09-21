#!/bin/bash
# Build the JPEG gain-map decoder for a dedicated worker; no pthreads or server required.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EMSDK="${EMSDK_ROOT:-${EMSDK:-$ROOT/build/emsdk}}"
[[ -f "$EMSDK/emsdk_env.sh" ]] || { echo 'Set EMSDK_ROOT to an Emscripten SDK.' >&2; exit 1; }
set +u
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
set -u
VERSION=2.0.2
SHA256=aa8d193bb887c348c419780511dd03b374f4e07af8812b6d3f80c8537cf1ef2c
BUILD="$ROOT/build/ultrahdr"
SOURCE="$BUILD/libultrahdr-$VERSION"
OUTPUT="$ROOT/web/public/hdr"
mkdir -p "$BUILD" "$OUTPUT"
if [[ ! -f "$SOURCE/ultrahdr_api.h" ]]; then
  curl --fail --location --retry 3 "https://codeload.github.com/google/libultrahdr/tar.gz/refs/tags/v$VERSION" -o "$BUILD/source.tar.gz"
  python3 - "$BUILD/source.tar.gz" "$SHA256" <<'PY'
import hashlib, sys
assert hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() == sys.argv[2], 'libultrahdr checksum mismatch'
PY
  tar -xzf "$BUILD/source.tar.gz" -C "$BUILD"
fi
emcmake cmake -S "$SOURCE" -B "$BUILD/wasm" \
  -DBUILD_SHARED_LIBS=OFF -DUHDR_BUILD_EXAMPLES=OFF -DUHDR_BUILD_TESTS=OFF \
  -DUHDR_ENABLE_INTRINSICS=OFF -DUHDR_ENABLE_HEIF=OFF -DUHDR_ENABLE_INSTALL=OFF
cmake --build "$BUILD/wasm" --target uhdr -j"${FOTUFILM_BUILD_JOBS:-8}"
em++ -O3 -I"$SOURCE" web/engine/hdr_wasm.cpp "$BUILD/wasm/libuhdr.a" \
  -sUSE_LIBJPEG=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB -sINITIAL_MEMORY=32MB \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker \
  -sEXPORTED_FUNCTIONS=_hdr_open,_hdr_decode,_hdr_width,_hdr_height,_hdr_gamut,_hdr_stride,_hdr_pixels,_hdr_error,_hdr_close,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPU16,UTF8ToString \
  -o "$OUTPUT/decoder.mjs"
cp "$SOURCE/LICENSE" "$OUTPUT/LICENSE.txt"
cp "$SOURCE/third_party/image_io/LICENSE" "$OUTPUT/IMAGE-IO-LICENSE.txt"
cp "$SOURCE/third_party/image_io/src/modp_b64/LICENSE" "$OUTPUT/BASE64-LICENSE.txt"
cp "$SOURCE/adobe-hdr-gain-map-license/NOTICE" "$OUTPUT/NOTICE.txt"
python3 - "$(em-config CACHE)/ports" "$OUTPUT" <<'PY'
from pathlib import Path
import sys
ports, output = map(Path, sys.argv[1:])
notices = sorted(ports.glob('libjpeg/*/README'))
if not notices:
    raise SystemExit('Missing libjpeg licence notice in Emscripten cache')
for source in notices:
    (output / f'{source.parent.name}-LICENSE.txt').write_bytes(source.read_bytes())
PY
echo 'Wrote web/public/hdr/decoder.{mjs,wasm} and codec notices.'
