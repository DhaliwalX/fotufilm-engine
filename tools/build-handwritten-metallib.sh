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
SDK_VERSION="$(xcrun --sdk "$SDK_NAME" --show-sdk-version)"
INPUT_HASH="$({
  printf '%s\n' "$SDK_NAME" "$SDK_VERSION" "$TARGET"
  shasum -a 256 "$0" "$SHADERS"/*.metal "$SHADERS"/*.metalinc
} | shasum -a 256 | awk '{print $1}')"
if [[ -f "$OUTPUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$INPUT_HASH" ]]; then
  echo "Hand-written Metal library current ($INPUT_HASH), skipping."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fotufilm-handwritten-metal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# FilmEngineInvocation is append-only. These offsets are intentionally explicit in the release
# compiler command: changing that ABI changes this script's content hash and therefore rebuilds
# the metallib. HandwrittenMetalConfigurationTests hold them against the Swift authority.
COMMON_DEFINES=(
  -DFOTUFILM_CFG_CURVE_SECONDARY=8768
  -DFOTUFILM_CFG_COUPLER_RELEASE_GAMMA=8792
  -DFOTUFILM_CFG_DONOR_RELEASE_GAMMA=8795
  -DFOTUFILM_CFG_DONOR_CURVE=8747
  -DFOTUFILM_CFG_DONOR_RELEASE=8753
  -DFOTUFILM_CFG_EXPOSURE_GAIN=61
  -DFOTUFILM_CFG_WHITE_BALANCE=450
  -DFOTUFILM_CFG_SCENE_ADJUST=453
  -DFOTUFILM_CFG_GRADE=470
  -DFOTUFILM_CFG_FRAME_SIZE=479
  -DFOTUFILM_CFG_TONE_GRID_SIZE=481
  -DFOTUFILM_CFG_TONE_GRID_A=483
  -DFOTUFILM_CFG_TONE_GRID_B=4579
  -DFOTUFILM_CFG_PAPER_RED=8687
  -DFOTUFILM_CFG_PAPER_BLUE=8693
  -DFOTUFILM_CFG_PAPER_MIDPOINT_RED=8699
  -DFOTUFILM_CFG_PAPER_MIDPOINT_BLUE=8700
  -DFOTUFILM_HLG_A=0.17883277f
  -DFOTUFILM_HLG_B=0.28466892f
  -DFOTUFILM_HLG_C=0.55991073f
  -DFOTUFILM_APPLE_LOG_R0=-0.05641088f
  -DFOTUFILM_APPLE_LOG_C=47.28711236f
  -DFOTUFILM_APPLE_LOG_BETA=0.00964052f
  -DFOTUFILM_APPLE_LOG_GAMMA=0.08550479f
  -DFOTUFILM_APPLE_LOG_DELTA=0.69336945f
  -DFOTUFILM_APPLE_LOG_TOE_SIGNAL=0.20855531595f
)
DELIVERY_DEFINES=(
  -DFOTUFILM_DELIVERY_HLG_HEADROOM=3.77411771f
  -DFOTUFILM_DELIVERY_HLG_DISPLAY_CEILING=4.92241859f
  -DFOTUFILM_DELIVERY_HLG_GAMMA=1.2f
  -DFOTUFILM_DELIVERY_P3_TO_2020_0=0.753833034f
  -DFOTUFILM_DELIVERY_P3_TO_2020_1=0.198597369f
  -DFOTUFILM_DELIVERY_P3_TO_2020_2=0.047569597f
  -DFOTUFILM_DELIVERY_P3_TO_2020_3=0.045743849f
  -DFOTUFILM_DELIVERY_P3_TO_2020_4=0.941777220f
  -DFOTUFILM_DELIVERY_P3_TO_2020_5=0.012478931f
  -DFOTUFILM_DELIVERY_P3_TO_2020_6=-0.001210340f
  -DFOTUFILM_DELIVERY_P3_TO_2020_7=0.017601717f
  -DFOTUFILM_DELIVERY_P3_TO_2020_8=0.983608623f
  -DFOTUFILM_DELIVERY_P3_TO_709_0=1.22494018f
  -DFOTUFILM_DELIVERY_P3_TO_709_1=-0.224940176f
  -DFOTUFILM_DELIVERY_P3_TO_709_2=0.0f
  -DFOTUFILM_DELIVERY_P3_TO_709_3=-0.042056955f
  -DFOTUFILM_DELIVERY_P3_TO_709_4=1.04205695f
  -DFOTUFILM_DELIVERY_P3_TO_709_5=0.0f
  -DFOTUFILM_DELIVERY_P3_TO_709_6=-0.019637555f
  -DFOTUFILM_DELIVERY_P3_TO_709_7=-0.078636046f
  -DFOTUFILM_DELIVERY_P3_TO_709_8=1.09827360f
)

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

compile_shader HandwrittenPointwise ffast-math \
  -DFOTUFILM_POINTWISE_TRANSFER_SAMPLES=1024 \
  -DFOTUFILM_POINTWISE_DECODE_SAMPLES=256
compile_shader HandwrittenComposedPointwise ffast-math

compile_shader HandwrittenFrameEndpoints ffast-math \
  -DFOTUFILM_ENDPOINT_CURVE_SAMPLES=2048 \
  -DFOTUFILM_ENDPOINT_TRANSFER_SAMPLES=1024
compile_shader HandwrittenGlobalMeasurements fno-fast-math \
  -DFOTUFILM_MEASUREMENT_REDUCTION_THREADS=256 \
  -DFOTUFILM_MEASUREMENT_FLARE_ITEMS=8
compile_shader HandwrittenSpectralHead ffast-math \
  -DFOTUFILM_HEAD_DECODE_SAMPLES=256
compile_shader HandwrittenCameraPassThrough ffast-math \
  -DFOTUFILM_CAMERA_DECODE_SAMPLES=256
compile_shader HandwrittenSpatial ffast-math
compile_shader HandwrittenDigitalDelivery fno-fast-math "${DELIVERY_DEFINES[@]}"
compile_shader HandwrittenStillDelivery fno-fast-math "${DELIVERY_DEFINES[@]}"
compile_shader HandwrittenCompositeTail ffast-math

mkdir -p "$(dirname "$OUTPUT")"
TEMP_OUTPUT="$WORK/HandwrittenFotufilm.metallib"
"$METALLIB" "${AIR_FILES[@]}" -o "$TEMP_OUTPUT"
cp "$TEMP_OUTPUT" "$OUTPUT"
printf '%s\n' "$INPUT_HASH" > "$STAMP"
echo "Built $OUTPUT"
