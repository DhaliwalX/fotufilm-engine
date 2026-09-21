#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/ultrahdr/libultrahdr-2.0.2"
[[ -f "$SOURCE/ultrahdr_api.h" ]] || { echo 'Run tools/build-hdr-wasm.sh first.' >&2; exit 1; }
cmake -S tools/hdr-fixtures -B build/ultrahdr/test-generator -DULTRAHDR_SOURCE="$SOURCE"
cmake --build build/ultrahdr/test-generator --target generate-hdr-fixture -j"${FOTUFILM_BUILD_JOBS:-8}"
mkdir -p build/ultrahdr/fixtures
build/ultrahdr/test-generator/generate-hdr-fixture build/ultrahdr/fixtures/gainmap.jpg
build/ultrahdr/test-generator/generate-hdr-fixture build/ultrahdr/fixtures/rotated.jpg 6 1
build/ultrahdr/test-generator/generate-hdr-fixture build/ultrahdr/fixtures/rec2020.jpg 1 2
