#!/bin/bash
# Deep PNG + ICC import. Sources and generated binaries stay in ignored build paths.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EMSDK="${EMSDK_ROOT:-$ROOT/build/emsdk}"
set +u
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
set -u
BUILD="$ROOT/build/png-decoder"
OUTPUT="$ROOT/web/public/png"
mkdir -p "$BUILD" "$OUTPUT" "$BUILD/include"
fetch() {
  local name="$1" url="$2" digest="$3"
  if [[ ! -f "$BUILD/$name.tar.gz" ]]; then curl --fail --location --retry 3 "$url" -o "$BUILD/$name.tar.gz"; fi
  python3 - "$BUILD/$name.tar.gz" "$digest" <<'PY'
import hashlib,sys
assert hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() == sys.argv[2], 'Decoder source checksum mismatch'
PY
  tar -xzf "$BUILD/$name.tar.gz" -C "$BUILD"
}
fetch png https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v1.6.58 a9d4df463d36a6e5f9c29bd6f4967312d17e996c1854f3511f833924eb1993cf
fetch lcms https://codeload.github.com/mm2/Little-CMS/tar.gz/refs/tags/lcms2.17 6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418
PNG="$BUILD/libpng-1.6.58"
LCMS="$BUILD/Little-CMS-lcms2.17"
cp "$PNG/scripts/pnglibconf.h.prebuilt" "$BUILD/include/pnglibconf.h"
PNG_SOURCES=()
for name in png pngerror pngget pngmem pngpread pngread pngrio pngrtran pngrutil pngset pngtrans pngwio pngwrite pngwtran pngwutil; do PNG_SOURCES+=("$PNG/$name.c"); done
emcc -O3 -msimd128 -I"$BUILD/include" -I"$PNG" -I"$LCMS/include" \
  web/engine/png_wasm.c "${PNG_SOURCES[@]}" "$LCMS"/src/*.c \
  -sUSE_ZLIB=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB -sINITIAL_MEMORY=32MB \
  -sABORTING_MALLOC=0 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker \
  -sEXPORTED_FUNCTIONS=_png_decoder_open,_png_decoder_decode,_png_decoder_rows,_png_decoder_width,_png_decoder_height,_png_decoder_capacity,_png_decoder_error,_png_decoder_close,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,UTF8ToString \
  -o "$OUTPUT/decoder.mjs"
cp "$PNG/LICENSE" "$OUTPUT/LIBPNG-LICENSE.txt"
cp "$LCMS/LICENSE" "$OUTPUT/LCMS-LICENSE.txt"
python3 - "$(em-config CACHE)/ports" "$OUTPUT" <<'PY'
from pathlib import Path
import sys
ports, output = map(Path,sys.argv[1:])
licences = sorted(ports.glob('zlib/*/README'))
if not licences: raise SystemExit('Missing zlib license notice')
(output/'ZLIB-LICENSE.txt').write_bytes(licences[-1].read_bytes())
PY
printf '%s\n' 'libpng 1.6.58 (libpng license) and Little CMS 2.17 (MIT), unmodified.' \
  'Source: https://github.com/pnggroup/libpng/tree/v1.6.58' \
  'Source: https://github.com/mm2/Little-CMS/tree/lcms2.17' > "$OUTPUT/SOURCE.txt"
echo 'Wrote web/public/png/decoder.{mjs,wasm} and codec notices.'
