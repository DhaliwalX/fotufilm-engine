#!/bin/bash
# Builds the Halide the Linux desktop kernels need: the pinned third_party/Halide with the Vulkan
# patches in tools/, into build/halide-linux-install (pass it to the kernel scripts as HALIDE_ROOT).
#   tools/build-halide-linux.sh [build-dir] [install-prefix]
#
# The patches go onto a copy of the pin in build/halide-linux-src, never into the submodule, so the
# checkout stays clean across updates. Without them Vulkan develops a flat, near-black frame, or
# reads every frame back uncached (tools/vulkan-parity/README.md). Each file says what it carries.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

SOURCE=build/halide-linux-src
BUILD="${1:-build/halide-linux-build}"
PREFIX="${2:-build/halide-linux-install}"

[[ -f third_party/Halide/CMakeLists.txt ]] || {
  echo "The Halide submodule is not checked out. Run:" >&2
  echo "  git submodule update --init third_party/Halide" >&2
  exit 1
}
PIN="$(git ls-tree HEAD third_party/Halide | awk '{print $3}')"
# Shared with the submodule's objects, so a moved pin is there without fetching.
[[ -d "$SOURCE/.git" ]] || git clone --quiet --shared --no-checkout third_party/Halide "$SOURCE"
# --force and clean put the copy back to the pin, so the patches apply to an unpatched tree however
# many times this is run.
git -C "$SOURCE" checkout --quiet --force --detach "$PIN"
git -C "$SOURCE" clean -fdxq
for patch in halide-vulkan-strict-float halide-vulkan-bool-uniforms halide-vulkan-allocation-padding halide-vulkan-readback-staging; do
  git -C "$SOURCE" apply "$PWD/tools/$patch.patch"
done

LLVM_PREFIX="${LLVM_ROOT:-$(llvm-config --prefix 2>/dev/null || true)}"
[[ -n "$LLVM_PREFIX" && -x "$LLVM_PREFIX/bin/llvm-config" ]] || {
  echo "LLVM not found. Halide needs LLVM, Clang and LLD 21 or newer with their CMake files, and the" >&2
  echo "Vulkan headers (Fedora: llvm-devel clang-devel lld-devel vulkan-headers zlib-ng-compat-devel" >&2
  echo "libxml2-devel libffi-devel). Set LLVM_ROOT or put llvm-config on PATH." >&2
  exit 1
}
echo "Halide ${PIN:0:9} with the Vulkan patches, against LLVM $("$LLVM_PREFIX/bin/llvm-config" --version)"

cmake -G Ninja -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DHalide_LLVM_ROOT="$LLVM_PREFIX" \
  -DHalide_WASM_BACKEND=OFF \
  -DWITH_TESTS=OFF -DWITH_TUTORIALS=OFF -DWITH_DOCS=OFF \
  -DWITH_UTILS=OFF -DWITH_PYTHON_BINDINGS=OFF -DWITH_SERIALIZATION=OFF

# The CUDA kernels need LLVM's NVPTX backend, which Halide treats as optional and drops quietly.
grep -q 'found components:.*NVPTX' "$BUILD/CMakeCache.txt" || {
  echo "This LLVM has no NVPTX component; the CUDA kernels cannot be generated." >&2
  exit 1
}

cmake --build "$BUILD" --parallel "${FOTUFILM_BUILD_JOBS:-$(nproc)}"
cmake --install "$BUILD" --prefix "$PREFIX" >/dev/null

echo
echo "Installed to $PREFIX. Build the desktop with HALIDE_ROOT=$PWD/$PREFIX cef/build.sh"
