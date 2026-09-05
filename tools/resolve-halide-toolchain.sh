#!/bin/bash
# Resolve an explicit HALIDE_ROOT, a locally unpacked toolchain, or Homebrew's Halide.
set -euo pipefail
cd "$(dirname "$0")/.."

HALIDE_PREFIX="${HALIDE_ROOT:-}"
if [[ -z "$HALIDE_PREFIX" ]]; then
  for candidate in build/halide-toolchain/*/; do
    if [[ -f "${candidate}include/Halide.h" ]]; then
      HALIDE_PREFIX="${candidate%/}"
      break
    fi
  done
fi
if [[ -z "$HALIDE_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  HALIDE_PREFIX="$(brew --prefix halide 2>/dev/null || true)"
fi
[[ -n "$HALIDE_PREFIX" && -f "$HALIDE_PREFIX/include/Halide.h" ]] || {
  echo "Halide not found. Set HALIDE_ROOT, unpack a toolchain into" >&2
  echo "build/halide-toolchain/, or 'brew install halide'." >&2
  exit 1
}
printf '%s\n' "$HALIDE_PREFIX"
