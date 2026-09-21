#!/bin/bash
# Decode TIFF samples and profiles without an 8-bit Canvas intermediate.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EMSDK="${EMSDK_ROOT:-$ROOT/build/emsdk}"
set +u
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
set -u
BUILD="$ROOT/build/tiff-decoder"
OUTPUT="$ROOT/web/public/tiff"
mkdir -p "$BUILD" "$OUTPUT"
fetch() {
  local archive="$1" url="$2" digest="$3"
  if [[ ! -f "$BUILD/$archive" ]]; then curl --fail --location --retry 3 "$url" -o "$BUILD/$archive"; fi
  python3 - "$BUILD/$archive" "$digest" <<'PY'
import hashlib,sys
assert hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() == sys.argv[2], 'TIFF decoder source checksum mismatch'
PY
  tar -xzf "$BUILD/$archive" -C "$BUILD"
}
fetch tiff-4.7.2.tar.gz https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz 672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a
fetch lcms2.17.tar.gz https://codeload.github.com/mm2/Little-CMS/tar.gz/refs/tags/lcms2.17 6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418
TIFF="$BUILD/tiff-4.7.2"
LCMS="$BUILD/Little-CMS-lcms2.17"
embuilder build zlib libjpeg
SYSROOT="$(em-config CACHE)/sysroot"
emcmake cmake -S "$TIFF" -B "$BUILD/cmake" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -Dtiff-static=ON \
  -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-install=OFF \
  -DCMAKE_C_FLAGS='-O3 -msimd128 -sUSE_ZLIB=1 -sUSE_LIBJPEG=1' \
  -DZLIB_INCLUDE_DIR="$SYSROOT/include" -DZLIB_LIBRARY="$SYSROOT/lib/wasm32-emscripten/libz.a" \
  -DJPEG_INCLUDE_DIR="$SYSROOT/include" -DJPEG_LIBRARY="$SYSROOT/lib/wasm32-emscripten/libjpeg.a" \
  -Dzlib=ON -Djpeg=ON -Dold-jpeg=ON -Dlibdeflate=OFF -Dlerc=OFF -Djbig=OFF -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF
cmake --build "$BUILD/cmake" --target tiff --parallel 4
emcc -O3 -msimd128 -I"$TIFF/libtiff" -I"$BUILD/cmake/libtiff" -I"$LCMS/include" \
  web/engine/tiff_wasm.c "$BUILD/cmake/libtiff/libtiff.a" "$LCMS"/src/*.c \
  -sUSE_ZLIB=1 -sUSE_LIBJPEG=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB -sINITIAL_MEMORY=32MB \
  -sABORTING_MALLOC=0 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker \
  -sEXPORTED_FUNCTIONS=_tiff_decoder_open,_tiff_decoder_block,_tiff_decoder_rows,_tiff_decoder_width,_tiff_decoder_height,_tiff_decoder_orientation,_tiff_decoder_depth,_tiff_decoder_blocks,_tiff_decoder_x,_tiff_decoder_y,_tiff_decoder_block_width,_tiff_decoder_block_height,_tiff_decoder_capacity,_tiff_decoder_error,_tiff_decoder_close,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,UTF8ToString \
  -o "$OUTPUT/decoder.mjs"
cp "$TIFF/LICENSE.md" "$OUTPUT/LIBTIFF-LICENSE.txt"
cp "$LCMS/LICENSE" "$OUTPUT/LCMS-LICENSE.txt"
python3 - "$(em-config CACHE)/ports" "$OUTPUT" <<'PY'
from pathlib import Path
import sys
ports, output = map(Path,sys.argv[1:])
for pattern,name in [('zlib/*/README','ZLIB-LICENSE.txt'),('libjpeg/*/README','JPEG-LICENSE.txt')]:
    sources=sorted(ports.glob(pattern))
    if not sources: raise SystemExit('Missing '+name)
    (output/name).write_bytes(sources[-1].read_bytes())
PY
printf '%s\n' 'libtiff 4.7.2 (libtiff license) and Little CMS 2.17 (MIT), unmodified.' \
  'Source: https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz' \
  'Source: https://github.com/mm2/Little-CMS/tree/lcms2.17' > "$OUTPUT/SOURCE.txt"
echo 'Wrote web/public/tiff/decoder.{mjs,wasm} and codec notices.'
