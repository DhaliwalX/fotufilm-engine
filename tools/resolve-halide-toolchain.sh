#!/bin/bash
# Prints the Halide prefix to build against, or fails with a message that says how to get one.
#
# One chain, shared by every script that needs a Halide: generate-halide-aot.sh, ios/build.sh and
# verify-aot-parity.sh each grew their own copy of this at one point, and it drifted — one still
# skipped straight to brew, never trying the pinned toolchain fetch-halide-toolchain.sh knows how
# to get. A caller that resolves its own Halide silently answers a different question than the one
# a build actually asks, and the divergence does not announce itself: the kernels it emits are
# just quietly built by whatever compiler the caller happened to find.
#
#   HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
#
# Order: HALIDE_ROOT, if the caller already knows; the pin, fetched or already unpacked; whatever
# else is sitting in build/halide-toolchain/ (fetch-halide-toolchain.sh failing offline with
# something already placed there by hand is the case this exists for); brew, last, because it
# tracks whatever version Homebrew last poured rather than the pin this project's kernels are
# generated against.
set -euo pipefail
cd "$(dirname "$0")/.."

HALIDE_PREFIX="${HALIDE_ROOT:-}"
if [[ -z "$HALIDE_PREFIX" && -x ci_scripts/fetch-halide-toolchain.sh ]]; then
  HALIDE_PREFIX="$(ci_scripts/fetch-halide-toolchain.sh 2>/dev/null || true)"
fi
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
