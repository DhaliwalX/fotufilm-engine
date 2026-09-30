#!/bin/bash
# Host-only bounded TIFF decoder, sanitizer and precision checks. No device runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/tiff-codec-test
mkdir -p "$OUT"
FLAGS=()
if [[ "$(uname -s)" == Darwin ]]; then
    FLAGS+=(-I"$(brew --prefix libtiff)/include" -L"$(brew --prefix libtiff)/lib")
    FLAGS+=(-I"$(brew --prefix little-cms2)/include" -L"$(brew --prefix little-cms2)/lib")
fi
"${CXX:-clang++}" -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DFFC_PORTABLE_CODECS=1 -ISources/CFotufilmCodecs/include "${FLAGS[@]}" \
    Sources/CFotufilmCodecs/{TIFFImport,DecodeTIFF,Colour,Exif,ImageMemory}.cpp tools/tiff-codec-test.cpp \
    -ltiff -llcms2 -pthread -o "$OUT/test"
"$OUT/test" "$OUT/fixtures"

if [[ "$(uname -s)" == Darwin ]]; then
    swift tools/verify-tiff-apple.swift "$OUT/fixtures"
fi
