#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <iphoneos|iphonesimulator|macosx> <output.metallib>" >&2
  exit 2
fi

SDK_NAME="$1"
OUTPUT="$2"
case "$SDK_NAME" in
  iphoneos) TARGET="air64-apple-ios18.0"; METAL_STANDARD="metal3.2" ;;
  iphonesimulator) TARGET="air64-apple-ios18.0-simulator"; METAL_STANDARD="metal3.2" ;;
  macosx) TARGET="air64-apple-macos14.0"; METAL_STANDARD="metal3.1" ;;
  *) echo "unsupported Metal SDK: $SDK_NAME" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADERS="$ROOT/Sources/FotufilmMetal/Shaders"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
STAMP="$OUTPUT.sha256"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fotufilm-handwritten-metal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# SwiftPM tracks the C header, Swift constants, and their dependencies. Build the host exporter
# before checking the stamp so a changed runtime definition can never reuse a stale metallib.
# Use a separate build directory to work inside SwiftPM-driven builds and tests without a lock
# cycle. The exporter evaluates constants only: it needs neither Halide nor a Metal device.
TOOL_BUILD="$ROOT/build/metal-defines"
FOTUFILM_DISABLE_HALIDE=1 swift build --package-path "$ROOT" --scratch-path "$TOOL_BUILD" \
  -c release --product fotufilm-metal-defines >&2
TOOL_BIN="$(FOTUFILM_DISABLE_HALIDE=1 swift build --package-path "$ROOT" \
  --scratch-path "$TOOL_BUILD" -c release --show-bin-path)"
"$TOOL_BIN/fotufilm-metal-defines" > "$WORK/definitions"
COMMON_DEFINES=()
while IFS= read -r definition; do
  COMMON_DEFINES+=("$definition")
done < "$WORK/definitions"

SDK_VERSION="$(xcrun --sdk "$SDK_NAME" --show-sdk-version)"
INPUT_HASH="$({
  printf '%s\n' "$SDK_NAME" "$SDK_VERSION" "$TARGET"
  shasum -a 256 "$0" "$SHADERS"/*.metal "$SHADERS"/*.metalinc
  cat "$WORK/definitions"
} | shasum -a 256 | awk '{print $1}')"
if [[ -f "$OUTPUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$INPUT_HASH" ]]; then
  echo "Hand-written Metal library current ($INPUT_HASH), skipping."
  exit 0
fi

METAL="$(xcrun --sdk "$SDK_NAME" --find metal)"
METALLIB="$(xcrun --sdk "$SDK_NAME" --find metallib)"
AIR_FILES=()

compile_shader() {
  local source="$1"
  local math_mode="$2"
  shift 2
  local air="$WORK/${source}.air"
  "$METAL" -c -target "$TARGET" -std="$METAL_STANDARD" -I "$SHADERS" \
    "-${math_mode}" "${COMMON_DEFINES[@]}" "$@" \
    "$SHADERS/${source}.metal" -o "$air"
  AIR_FILES+=("$air")
}

compile_shader HandwrittenPointwise ffast-math
compile_shader HandwrittenComposedPointwise ffast-math
compile_shader HandwrittenFrameEndpoints ffast-math
compile_shader HandwrittenGlobalMeasurements fno-fast-math
compile_shader HandwrittenSpectralHead ffast-math
compile_shader HandwrittenCameraPassThrough ffast-math
compile_shader HandwrittenSpatial ffast-math
compile_shader HandwrittenDigitalDelivery fno-fast-math
compile_shader HandwrittenStillDelivery fno-fast-math
compile_shader HandwrittenCompositeTail ffast-math

mkdir -p "$(dirname "$OUTPUT")"
TEMP_OUTPUT="$WORK/HandwrittenFotufilm.metallib"
"$METALLIB" "${AIR_FILES[@]}" -o "$TEMP_OUTPUT"
cp "$TEMP_OUTPUT" "$OUTPUT"
printf '%s\n' "$INPUT_HASH" > "$STAMP"
echo "Built $OUTPUT"
