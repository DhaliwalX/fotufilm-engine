#!/bin/bash
# Builds the browser engine: the reference Halide pipeline as WebAssembly, the module that drives
# it, and one exported pack per installed stock.
#
# The order matters. A pack carries the stock's feature mask, and the mask decides which develop
# variant that stock needs — the same choice `develop_pipeline_for` makes natively. So the packs
# are exported first and the kernels generated for the masks they actually ask for, rather than
# for all 512 combinations.
#
# The stage sidecars exported alongside them do not widen that set. Their masks describe a pipeline
# with parts switched off, and none of those variants is built: a stage is developed through its
# stock's own kernel and switched off by its configuration instead. See `dispatchMask` in
# web/src/engine.js.
#
# Two roads come out of this: a WebGPU module the browser prefers, and a SIMD one it falls back
# to. The WebGPU road needs a Halide that speaks the promise-based webgpu.h — see the note above
# FOTUFILM_WEBGPU_HALIDE below — and is skipped, with a message, when there is no such Halide here.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="${1:-build/halide-wasm}"
# Match the bundled 1600x900 scene at native resolution. The environment override remains useful
# for constrained previews or a deployment with a different known target size.
PACK_SIZE="${FOTUFILM_WASM_PACK_SIZE:-1600x900}"
EMSDK="${EMSDK_ROOT:-build/emsdk}"

# The pinned Halide first, then whatever is installed. The pin is what the goldens were generated
# against; a system Halide is a convenience, not the reference.
HALIDE_PREFIX="${HALIDE_ROOT:-}"
if [[ -z "$HALIDE_PREFIX" && -f build/halide-install/include/Halide.h ]]; then
  HALIDE_PREFIX=build/halide-install
fi
if [[ -z "$HALIDE_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  HALIDE_PREFIX="$(brew --prefix halide 2>/dev/null || true)"
fi
[[ -n "$HALIDE_PREFIX" && -f "$HALIDE_PREFIX/include/Halide.h" ]] || {
  echo "Halide not found. Install a compatible Halide toolchain," >&2
  echo "or set HALIDE_ROOT, or 'brew install halide'." >&2
  exit 1
}
echo "Halide: $HALIDE_PREFIX"

# The Halide that builds the WebGPU road, which is not the same one that builds the SIMD road.
# It has to speak the promise-based webgpu.h that a current Emscripten's emdawnwebgpu port
# provides — Halide's released runtime still wants the pre-Future header, which pins the link to
# Emscripten 3.1.x, whose bundled binaryen then rejects the wasm features Halide's own LLVM emits.
# Halide PR #8955 is what breaks that triangle. It also needs one line the PR does not carry: the
# runtime raises five adapter limits and omits maxStorageBuffersPerShaderStage, so the combine
# kernel's nine storage buffers are refused against a default of eight. See
# tools/halide-webgpu-storage-limit.patch.
WEBGPU_HALIDE="${FOTUFILM_WEBGPU_HALIDE:-}"
if [[ -z "$WEBGPU_HALIDE" && -f build/halide-pr-install/include/Halide.h ]]; then
  WEBGPU_HALIDE=build/halide-pr-install
fi

# A current Emscripten, deliberately: Halide's LLVM stamps wasm features into the object that
# Emscripten 3.1.x's bundled wasm-opt has never heard of — bulk-memory-opt among them — and emcc
# forwards them verbatim. Pointing 3.1.x at a newer standalone binaryen gets past that, but then
# its JS optimiser and that binaryen disagree about the import-minification handshake and the
# module fails to instantiate.
[[ -f "$EMSDK/emsdk_env.sh" ]] || {
  echo "Emscripten not found at $EMSDK. Install it with:" >&2
  echo "  git clone --depth 1 https://github.com/emscripten-core/emsdk.git $EMSDK" >&2
  echo "  $EMSDK/emsdk install latest && $EMSDK/emsdk activate latest" >&2
  exit 1
}

mkdir -p "$OUTPUT"

echo "Exporting stock packs at ${PACK_SIZE}…"
swift build -c release --product fotufilm >/dev/null
mkdir -p web/public/packs
cp licenses/FILM-PROFILES.txt licenses/CC-BY-SA-4.0.txt web/public/packs/
rm -f web/public/packs/*.pack web/public/packs/*.stages
INDEX="web/public/packs/index.json"
printf '[' > "$INDEX"
FIRST=1
MASKS=()
while IFS=$'\t' read -r id name _; do
  [[ -n "$id" ]] || continue
  ./.build/release/fotufilm --dump-wasm-pack "web/public/packs/$id.pack" \
    --stock "$id" --pack-size "$PACK_SIZE" >/dev/null
  # The sidecar the pipeline walk reads: the same export once per stage, stored as what each
  # stage does not share with the finished film. It is fetched only when someone takes the
  # pipeline apart, so it rides alongside the pack rather than inside it.
  ./.build/release/fotufilm --dump-wasm-stages "web/public/packs/$id.stages" \
    --stock "$id" --pack-size "$PACK_SIZE" >/dev/null
  # The pack header keeps the feature mask at byte 16; see --dump-wasm-pack in main.swift.
  mask="$(od -An -td4 -j16 -N4 "web/public/packs/$id.pack" | tr -d ' ')"
  MASKS+=("$mask")
  [[ $FIRST -eq 1 ]] || printf ',' >> "$INDEX"
  FIRST=0
  printf '{"id":"%s","name":"%s"}' "$id" "$name" >> "$INDEX"
  echo "  $id  mask $mask"
done < <(./.build/release/fotufilm --list-stocks)
printf ']' >> "$INDEX"

# The scene the demo opens on, and the same scene already developed stage by stage for a browser
# with no WebAssembly to develop it in. One stock only: seven of these would be seven downloads
# nobody in that position asked for, and the point is to show what the pipeline does, not to offer
# a choice that the working demo offers anyway. A colour negative, so the print stage has something
# to do — on a reversal stock the slide is its own output medium and the last two frames match.
FALLBACK_STOCK="${FOTUFILM_FALLBACK_STOCK:-gold200}"
echo "Rendering the static fallback through ${FALLBACK_STOCK}…"
SCENE_SOURCE="web/public/fotufilm_tagline.png"
SCENE_WIDTH="${PACK_SIZE%x*}"
SCENE_HEIGHT="${PACK_SIZE#*x}"
[[ -f "$SCENE_SOURCE" ]] || {
  echo "Default scene not found at $SCENE_SOURCE." >&2
  exit 1
}
sips -s format png -Z "$SCENE_WIDTH" "$SCENE_SOURCE" --out web/public/scene.png >/dev/null
sips --padToHeightWidth "$SCENE_HEIGHT" "$SCENE_WIDTH" --padColor 000000 \
  web/public/scene.png --out web/public/scene.png >/dev/null
rm -rf web/public/fallback
./.build/release/fotufilm web/public/scene.png web/public/fallback --stages \
  --stock "$FALLBACK_STOCK" >/dev/null
# JPEG for the web. The CLI writes lossless PNG because it writes what the film made, and 6.6 MB
# of that is not what a browser which cannot run the engine should have to download to see it.
for png in web/public/fallback/*.png; do
  sips -s format jpeg -s formatOptions 82 "$png" --out "${png%.png}.jpg" >/dev/null
  rm "$png"
done
sed -i '' 's/\.png"/.jpg"/g' web/public/fallback/index.json
echo "  $(du -sh web/public/fallback | cut -f1) in web/public/fallback"

echo "Building the generator…"
HOST_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo /)"
env -u SDKROOT clang++ -std=c++17 -O2 \
  ${HOST_SDK:+-isysroot "$HOST_SDK"} \
  -I"$HALIDE_PREFIX/include" -ISources/FotufilmHalide/include \
  tools/generate_halide_wasm_cpu.cpp \
  -L"$HALIDE_PREFIX/lib" -lHalide -Wl,-rpath,"$HALIDE_PREFIX/lib" \
  -o "$OUTPUT/generate"

echo "Generating kernels…"
rm -rf "$OUTPUT/cpu"
"$OUTPUT/generate" "$OUTPUT/cpu" "${MASKS[@]}"

# Build the dispatch table from the kernels generated for the installed stocks.
# This keeps example and custom stock feature masks in sync with the linked archives.
python3 - "$OUTPUT/cpu" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
variants = sorted(int(p.stem.removeprefix('develop_'))
                  for p in root.glob('develop_*.a')
                  if re.fullmatch(r'develop_[0-9]+', p.stem))
if not variants:
    raise SystemExit('No develop kernels were generated.')
for variant in variants:
    if not (root / f'develop_{variant}.h').is_file():
        raise SystemExit(f'Missing header for develop_{variant}.')
(root / 'fotufilm_wasm_variants.h').write_text(''.join(
    f'#include "develop_{v}.h"\n' for v in variants))
(root / 'fotufilm_wasm_variants.inc').write_text(''.join(
    f'case {v}: status = develop_{v}(FOTUFILM_DEVELOP_ARGUMENTS); break;\n'
    for v in variants))
PY

echo "Linking the WebAssembly module…"
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
mkdir -p web/public
em++ -O3 web/engine/fotufilm_wasm_cpu.cpp \
  "$OUTPUT"/cpu/develop_*.a "$OUTPUT"/cpu/print_*.a \
  -I Sources/FotufilmHalide/include -I "$OUTPUT/cpu" \
  -msimd128 -sALLOW_MEMORY_GROWTH=1 \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
  -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPF32 \
  -sEXPORTED_FUNCTIONS=_fotufilm_wasm_cpu_render,_fotufilm_wasm_set_exposure,_fotufilm_wasm_set_scene,_fotufilm_wasm_set_white_balance,_fotufilm_wasm_set_grain,_fotufilm_wasm_configuration_count,_fotufilm_wasm_lut_count,_malloc,_free \
  -o web/public/fotufilm.mjs

# The WebGPU road. One generator for every stock rather than one per mask: the fused kernel takes
# its stages from the feature mask at run time, so colour and monochrome are the only two shapes.
if [[ -n "$WEBGPU_HALIDE" && -f "$WEBGPU_HALIDE/include/Halide.h" ]]; then
  echo "Building the WebGPU generator… ($WEBGPU_HALIDE)"
  env -u SDKROOT clang++ -std=c++17 -O2 \
    ${HOST_SDK:+-isysroot "$HOST_SDK"} \
    -DFOTUFILM_HALIDE_ENABLED=1 \
    -I"$WEBGPU_HALIDE/include" -ISources/FotufilmHalide/include \
    tools/generate_halide_wasm.cpp \
    -L"$WEBGPU_HALIDE/lib" -lHalide -Wl,-rpath,"$WEBGPU_HALIDE/lib" \
    -o "$OUTPUT/generate-webgpu"

  echo "Generating WGSL kernels…"
  rm -rf "$OUTPUT/webgpu"
  "$OUTPUT/generate-webgpu" "$OUTPUT/webgpu" --webgpu

  echo "Linking the WebGPU module…"
  # JSPI, not Asyncify: the runtime waits on the adapter and on buffer mapping, and JSPI is what
  # a current Emscripten instruments those waits with. The export name carries no leading
  # underscore here, the opposite of EXPORTED_FUNCTIONS — spell it wrong and the wrapping is
  # silently skipped, and the first suspend traps.
  em++ -O3 web/engine/fotufilm_wasm.cpp \
    "$OUTPUT"/webgpu/color_float.a "$OUTPUT"/webgpu/monochrome_float.a \
    -I Sources/FotufilmHalide/include -I "$OUTPUT/webgpu" \
    --use-port=emdawnwebgpu -sJSPI -sJSPI_EXPORTS=fotufilm_wasm_render \
    -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPF32 \
    -sEXPORTED_FUNCTIONS=_fotufilm_wasm_render,_fotufilm_wasm_set_exposure,_fotufilm_wasm_set_scene,_fotufilm_wasm_set_white_balance,_fotufilm_wasm_set_grain,_fotufilm_wasm_configuration_count,_fotufilm_wasm_lut_count,_fotufilm_wasm_packed_count,_malloc,_free \
    -o web/public/fotufilm-webgpu.mjs
else
  rm -f web/public/fotufilm-webgpu.mjs web/public/fotufilm-webgpu.wasm
  echo
  echo "No WebGPU-capable Halide; the browser will develop on the CPU."
  echo "Set FOTUFILM_WEBGPU_HALIDE to a compatible toolchain to enable WebGPU."
fi

echo
echo "Wrote web/public/fotufilm.{mjs,wasm}$([[ -f web/public/fotufilm-webgpu.mjs ]] && echo ', fotufilm-webgpu.{mjs,wasm}') and $(ls web/public/packs/*.pack | wc -l | tr -d ' ') packs."

node tools/test-wasm.mjs
