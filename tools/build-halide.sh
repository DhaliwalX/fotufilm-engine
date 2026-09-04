#!/bin/bash
# Builds the pinned Halide from third_party/Halide into build/halide-install.
#
# The pin exists so the kernels are compiled by a known Halide rather than whatever the package
# manager last poured — the generated code is the product here, and a compiler upgrade is a change
# to it. `git -C third_party/Halide log -1` says which one; moving it is a commit.
#
# Homebrew splits LLVM and LLD into separate formulae, and Halide drops the WebAssembly target
# entirely when it cannot find LLD — silently enough that the first sign is a generator refusing a
# wasm target. Both are checked here instead.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=third_party/Halide
BUILD="${1:-build/halide-build}"
PREFIX="${2:-build/halide-install}"

# --webgpu builds a second Halide, from a pull request rather than from the pin, because the
# browser's GPU road needs a WebGPU runtime that speaks the promise-based webgpu.h. It is kept out
# of the submodule on purpose: the pin is what the goldens were generated against and follows
# Halide's main, and an unmerged branch has no business being that.
WEBGPU_PR="${FOTUFILM_HALIDE_WEBGPU_PR:-8955}"
if [[ "${1:-}" == "--webgpu" ]]; then
  SOURCE=build/halide-pr
  BUILD=build/halide-pr-build
  PREFIX=build/halide-pr-install
  if [[ ! -d "$SOURCE/.git" ]]; then
    echo "Fetching Halide PR #$WEBGPU_PR…"
    git clone --filter=blob:none https://github.com/halide/Halide.git "$SOURCE"
  fi
  git -C "$SOURCE" fetch --quiet origin "refs/pull/$WEBGPU_PR/head"
  git -C "$SOURCE" checkout --quiet --force FETCH_HEAD
  # --force above puts the checkout back to the PR's own content, so the patch always applies to
  # an unpatched tree however many times this is run.
  git -C "$SOURCE" apply "$PWD/tools/halide-webgpu-storage-limit.patch"
  echo "Halide PR #$WEBGPU_PR at $(git -C "$SOURCE" rev-parse --short HEAD), plus the limit patch"
fi

[[ -f "$SOURCE/CMakeLists.txt" ]] || {
  echo "The Halide submodule is not checked out. Run:" >&2
  echo "  git submodule update --init third_party/Halide" >&2
  exit 1
}

LLVM_PREFIX="${LLVM_ROOT:-}"
if [[ -z "$LLVM_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
fi
[[ -n "$LLVM_PREFIX" && -x "$LLVM_PREFIX/bin/llvm-config" ]] || {
  echo "LLVM not found. Halide needs 21 or newer. Set LLVM_ROOT or 'brew install llvm'." >&2
  exit 1
}

LLD_PREFIX="${LLD_ROOT:-}"
if [[ -z "$LLD_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
  LLD_PREFIX="$(brew --prefix lld 2>/dev/null || true)"
fi
[[ -n "$LLD_PREFIX" && -d "$LLD_PREFIX/lib/cmake/lld" ]] || {
  echo "LLD not found, and without it Halide builds no WebAssembly target." >&2
  echo "Set LLD_ROOT or 'brew install lld'." >&2
  exit 1
}

echo "Halide $(git -C "$SOURCE" rev-parse --short HEAD) against LLVM $("$LLVM_PREFIX/bin/llvm-config" --version)"

cmake -G Ninja -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DHalide_LLVM_ROOT="$LLVM_PREFIX" \
  -DLLD_DIR="$LLD_PREFIX/lib/cmake/lld" \
  -DWITH_TESTS=OFF -DWITH_TUTORIALS=OFF -DWITH_DOCS=OFF \
  -DWITH_UTILS=OFF -DWITH_PYTHON_BINDINGS=OFF

# Halide reports the LLVM components it actually found. WebAssembly missing here means every wasm
# target fails later with a much less helpful message, so it is worth failing on now.
grep -q 'found components:.*WebAssembly' "$BUILD/CMakeCache.txt" || {
  echo "This LLVM has no WebAssembly component; the browser engine cannot be generated." >&2
  exit 1
}

cmake --build "$BUILD" -j
cmake --install "$BUILD" --prefix "$PREFIX" >/dev/null

echo
echo "Installed to $PREFIX. tools/build-wasm.sh picks it up from there."
