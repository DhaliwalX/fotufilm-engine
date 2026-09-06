#!/bin/bash
# Build the browser RAW decoder without pthreads: ordinary static hosting is enough.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
EMSDK="${EMSDK_ROOT:-$ROOT/build/emsdk}"
[[ -f "$EMSDK/emsdk_env.sh" ]] || { echo 'Set EMSDK_ROOT to an Emscripten SDK.' >&2; exit 1; }
set +u
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
set -u
VERSION=0.22.2
SHA256=de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa
BUILD="$ROOT/build/raw"
SOURCE="$BUILD/LibRaw-$VERSION"
mkdir -p "$BUILD" "$ROOT/web/public/raw"
if [[ ! -f "$SOURCE/configure" ]]; then
  curl --fail --location --retry 3 "https://www.libraw.org/data/LibRaw-$VERSION.tar.gz" -o "$BUILD/source.tar.gz"
  python3 - "$BUILD/source.tar.gz" "$SHA256" <<'PY'
import hashlib, sys
assert hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() == sys.argv[2], 'LibRaw checksum mismatch'
PY
  tar -xzf "$BUILD/source.tar.gz" -C "$BUILD"
fi
BUILD_KEY="$(emcc --version | head -n 1) exceptions-v1"
if [[ ! -f "$SOURCE/lib/.libs/libraw.a" || "$(cat "$SOURCE/.fotufilm-build-key" 2>/dev/null || true)" != "$BUILD_KEY" ]]; then
  (
    cd "$SOURCE"
    if [[ -f Makefile ]]; then emmake make clean >/dev/null; fi
    emconfigure ./configure --host=wasm32-unknown-none --disable-shared \
      --disable-examples --disable-openmp --disable-lcms --enable-jpeg --enable-zlib \
      CFLAGS='-O3 -DUSE_JPEG -DUSE_JPEG8 -DUSE_ZLIB -sUSE_LIBJPEG=1 -sUSE_ZLIB=1' \
      CXXFLAGS='-O3 -fexceptions -DUSE_JPEG -DUSE_JPEG8 -DUSE_ZLIB -sUSE_LIBJPEG=1 -sUSE_ZLIB=1' \
      LDFLAGS='-sUSE_LIBJPEG=1 -sUSE_ZLIB=1' \
      ZLIB_CFLAGS='-sUSE_ZLIB=1' ZLIB_LIBS='-sUSE_ZLIB=1'
    emmake make -j"${FOTUFILM_BUILD_JOBS:-8}" lib/libraw.la
    printf '%s' "$BUILD_KEY" > .fotufilm-build-key
  )
fi
em++ -O3 -fexceptions -I"$SOURCE" web/engine/raw_wasm.cpp "$SOURCE/lib/.libs/libraw.a" \
  -sUSE_LIBJPEG=1 -sUSE_ZLIB=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB \
  -sINITIAL_MEMORY=32MB -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker \
  -sEXPORTED_FUNCTIONS=_raw_open,_raw_unpack,_raw_process,_raw_width,_raw_height,_raw_colors,_raw_pixels,_raw_close,_raw_error,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPU16,UTF8ToString \
  -o web/public/raw/decoder.mjs
cp "$SOURCE/LICENSE.CDDL" "$SOURCE/COPYRIGHT" web/public/raw/
python3 - "$(em-config CACHE)/ports" "$ROOT/web/public/raw" <<'PYLICENSE'
from pathlib import Path
import sys
ports, output = map(Path, sys.argv[1:])
for family, pattern in [('libjpeg', 'libjpeg/*/README'), ('zlib', 'zlib/*/LICENSE')]:
    notices = sorted(ports.glob(pattern))
    if not notices:
        raise SystemExit(f'Missing {family} licence notice in Emscripten cache')
    for source in notices:
        (output / f'{source.parent.name}-LICENSE.txt').write_bytes(source.read_bytes())
PYLICENSE
echo 'Wrote web/public/raw/decoder.{mjs,wasm} and LibRaw notices.'
