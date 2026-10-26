#!/bin/bash
# Renders the baseline matrix and compares it with the committed fingerprints, or records them.
#
#   tools/render-baseline.sh [check|update] [cpu] [metal] [aot] [wasm]
#
# With no backends it runs cpu and metal. Each backend has its own references, made by that
# backend, in Tests/RenderBaseline/references; see the README there for the matrix.
#
#   cpu, metal  RenderBaselineTests: the editor's own develop on the Halide CPU and Metal
#               developers, four inputs through every output medium of one film.
#   aot         tools/verify-aot-parity.sh: every shipped Metal AOT variant on its fixture. The
#               AOT-against-JIT check runs too, and fails this backend if it fails.
#   wasm        tools/render-baseline-wasm.mjs: the browser engine and its orchestration, on the
#               chart's scene light and JPEG. Needs web/public built by tools/build-wasm.sh.
#
# A change meant to alter renders is recorded with `update`, which prints what moved; review that
# list before committing the new references.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=check
if [[ "${1:-}" == check || "${1:-}" == update ]]; then
  MODE="$1"
  shift
fi
BACKENDS=("$@")
[[ ${#BACKENDS[@]} -gt 0 ]] || BACKENDS=(cpu metal)
for backend in "${BACKENDS[@]}"; do
  case "$backend" in cpu|metal|aot|wasm) ;; *) echo "Unknown backend '$backend'." >&2; exit 2 ;; esac
done
wants() { [[ " ${BACKENDS[*]} " == *" $1 "* ]]; }

# The references are only as reproducible as the compiler that made them: the CPU and Metal
# kernels are compiled at run time by whatever Halide the build links. Pin the toolchain the AOT
# kernels use rather than whatever Homebrew holds, and say which it was.
HALIDE_ROOT="$(tools/resolve-halide-toolchain.sh)"
[[ "$HALIDE_ROOT" == /* ]] || HALIDE_ROOT="$PWD/$HALIDE_ROOT"
export HALIDE_ROOT
echo "Halide: $HALIDE_ROOT"

OUT="build/render-baseline"
rm -rf "$OUT"
mkdir -p "$OUT"
SCRATCH="${FOTUFILM_RENDER_BASELINE_SCRATCH:-.build}"

tests=()
wants cpu && tests+=(testCPU)
wants metal && tests+=(testMetal)
wants wasm && tests+=(testWriteWasmInputs)
if [[ ${#tests[@]} -gt 0 ]]; then
  filter="RenderBaselineTests/($(IFS='|'; echo "${tests[*]}"))"
  echo "--- rendering: ${tests[*]} ---"
  FOTUFILM_RENDER_BASELINE_OUT="$PWD/$OUT" \
    swift test -c release --scratch-path "$SCRATCH" --filter "$filter"
fi

failed=()
compare() {
  python3 tools/render-baseline.py "$MODE" --backend "$1" "$2" || failed+=("$1")
}

for backend in cpu metal; do
  wants "$backend" && compare "$backend" "$OUT/$backend"
done

if wants aot; then
  echo "--- aot ---"
  if bash tools/verify-aot-parity.sh; then
    compare aot build/aot-parity/aot
  else
    failed+=(aot)
  fi
fi

if wants wasm; then
  echo "--- wasm ---"
  [[ -f web/public/fotufilm.mjs && -f web/public/packs/media.json ]] || {
    echo "No browser engine in web/public: run tools/build-wasm.sh first." >&2
    exit 1
  }
  node tools/render-baseline-wasm.mjs "$OUT/inputs" "$OUT/wasm"
  compare wasm "$OUT/wasm"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Render baseline $MODE failed: ${failed[*]}" >&2
  exit 1
fi
echo "Render baseline $MODE passed: ${BACKENDS[*]}"
