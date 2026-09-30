#!/bin/bash
# RAW-only portable C boundary, including on macOS without changing the shipping ImageIO path.
# Needs LibRaw 0.22.2, lcms2, a C++17 compiler and Node. No camera images or device runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/raw-codec-test
mkdir -p "$OUT"
node tools/generate-raw-codec-fixtures.mjs "$OUT/fixtures"
FIXTURES=("$OUT/fixtures")
if [[ "${1:-}" == --cameras ]]; then
    python3 tools/fetch-raw-codec-cameras.py "$OUT/cameras"
    FIXTURES+=("$OUT/cameras")
elif [[ $# != 0 ]]; then
    echo 'Usage: tools/test-raw-codec.sh [--cameras]' >&2
    exit 1
fi
FLAGS=()
if [[ "$(uname -s)" == Darwin ]]; then
    FLAGS+=(-I"$(brew --prefix libraw)/include" -L"$(brew --prefix libraw)/lib")
    FLAGS+=(-I"$(brew --prefix little-cms2)/include" -L"$(brew --prefix little-cms2)/lib")
fi
"${CXX:-clang++}" -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DFFC_PORTABLE_CODECS=1 -ISources/CFotufilmCodecs/include "${FLAGS[@]}" \
    Sources/CFotufilmCodecs/{RawDecode,Colour,Exif,ImageMemory}.cpp tools/raw-codec-test.cpp \
    -lraw_r -llcms2 -pthread -o "$OUT/test"
"$OUT/test" "${FIXTURES[@]}"
