#!/bin/bash
# Builds a portable Halide binary toolchain: LLVM, Clang and LLD compiled from source and linked
# statically into libHalide, so the result carries nothing back to the machine that built it.
#
# This is not tools/build-halide.sh. That script links against Homebrew's LLVM and LLD directly —
# fine for building this Mac's own generator, useless for anything that leaves it: the resulting
# libHalide.dylib depends on /opt/homebrew/opt/llvm and /opt/homebrew/opt/lld at their exact
# installed paths, which do not exist on a CI runner or an Xcode Cloud image. Halide's own official
# releases avoid this by linking LLVM and LLD in statically; this script does the same.
#
#   tools/build-halide-toolchain.sh
#
# Run it once per Halide version bump. The output is a self-contained tree at
#   build/halide-toolchain-src/Halide-<version>-arm-64-osx/
# which prints its own otool -L for the final dylib so the self-containment claim is checked
# rather than assumed — only libSystem, libz and libc++ should be there, matching Halide's own
# published binaries. tools/publish-halide-toolchain.sh packages and publishes it from there.
#
# Why this needs a full LLVM+Clang+LLD build rather than reusing Homebrew's:
#   - Homebrew's llvm formula links its own libLLVM.dylib and exports that as the only interface
#     find_package(LLVM) sees, regardless of what the consumer's BUILD_SHARED_LIBS says — the
#     static/shared choice was baked in when Homebrew built it, not something a downstream
#     configure can override.
#   - Homebrew's lld formula ships no static archives at all, only shared liblld*.dylib.
# Both mean a static libHalide has to start from LLVM+LLD source, not a package manager.
#
# Halide_ENABLE_RTTI has to track LLVM_ENABLE_RTTI (Halide's own CMakeLists makes this a hard
# DEPENDS), and LLVM's default is off. Off breaks exception handling across the library boundary —
# a generator built against this Halide fails to link with "typeinfo for Halide::Error" undefined,
# because the thrown/caught type has no typeinfo to match without RTTI. LLVM_ENABLE_RTTI=ON here
# is what makes Halide::Error catchable outside libHalide.a, which every Halide generator's main()
# relies on.
#
# LLVM_ENABLE_ZSTD is turned off, and Halide's WASM testing backend (Halide_WASM_BACKEND, which
# defaults to "wabt") is turned off too — not because either is wrong to want, but because zstd's
# own optional compression path and wabt's own CMake package both reach for OpenSSL's libcrypto on
# this machine, and that is one more Homebrew dylib path this toolchain would otherwise carry.
# Nothing this project uses touches either: the AOT kernel generator runs fixed schedules, not
# Halide's own autoscheduler-driven compression paths, and the project's own WASM engine
# (tools/build-wasm.sh) is unrelated to Halide's internal WASM *testing* JIT.
#
# LLVM_TARGETS_TO_BUILD is scoped to AArch64, X86 and WebAssembly — what this repository's Halide
# generators actually target (macOS/iOS host codegen, Intel Mac OFX builds, and the browser wasm
# engine) — rather than every backend LLVM ships. That is most of why this comes out at roughly a
# sixth the size of Halide's official all-targets release.
set -euo pipefail
cd "$(dirname "$0")/.."

HALIDE_VERSION="22.0.0"
LLVM_TAG="llvmorg-22.1.8"                    # Pinned to match the Homebrew llvm/lld this was
                                              # cross-checked against; bump deliberately.
SRC="build/halide-toolchain-src"
LLVM_SRC="$SRC/llvm-project"
LLVM_BUILD="$SRC/llvm-build"
LLVM_INSTALL="$SRC/llvm-install"
HALIDE_BUILD="$SRC/halide-build"
PREFIX_MAP_FLAGS="-ffile-prefix-map=$PWD=/__fotufilm_build_root__ -fdebug-prefix-map=$PWD=/__fotufilm_build_root__ -fmacro-prefix-map=$PWD=/__fotufilm_build_root__"

[[ -f third_party/Halide/CMakeLists.txt ]] || {
  echo "The Halide submodule is not checked out. Run:" >&2
  echo "  git submodule update --init third_party/Halide" >&2
  exit 1
}
HALIDE_COMMIT="$(git -C third_party/Halide rev-parse HEAD)"

mkdir -p "$SRC"

# A blobless, cone-mode sparse checkout: llvm-project is the whole LLVM monorepo, and only
# llvm/, clang/ and lld/ (plus the cmake/ modules and third-party bits they reach into) are
# needed to build the three projects Halide and this toolchain want.
if [[ ! -d "$LLVM_SRC/.git" ]]; then
  echo "Fetching llvm-project at $LLVM_TAG (sparse: llvm, clang, lld)…"
  git init -q "$LLVM_SRC"
  git -C "$LLVM_SRC" remote add origin https://github.com/llvm/llvm-project.git
  git -C "$LLVM_SRC" config core.sparseCheckout true
  git -C "$LLVM_SRC" sparse-checkout init --cone
  git -C "$LLVM_SRC" sparse-checkout set \
    lld clang cmake llvm third-party libunwind runtimes compiler-rt
  git -C "$LLVM_SRC" fetch --depth 1 origin "$LLVM_TAG"
  git -C "$LLVM_SRC" checkout -q FETCH_HEAD
fi

echo "Configuring LLVM + Clang + LLD (static, AArch64;X86;WebAssembly, RTTI on)…"
cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$LLVM_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$PREFIX_MAP_FLAGS" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP_FLAGS" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86;WebAssembly" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF -DLLD_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DCMAKE_INSTALL_PREFIX="$PWD/$LLVM_INSTALL"

echo "Building LLVM + Clang + LLD — this is the long step, easily 30+ minutes from cold."
cmake --build "$LLVM_BUILD" -j"$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)"
cmake --install "$LLVM_BUILD" >/dev/null

echo "Configuring Halide $HALIDE_COMMIT against the static toolchain…"
cmake -G Ninja -S third_party/Halide -B "$HALIDE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$PREFIX_MAP_FLAGS" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP_FLAGS" \
  -DLLVM_DIR="$PWD/$LLVM_INSTALL/lib/cmake/llvm" \
  -DClang_DIR="$PWD/$LLVM_INSTALL/lib/cmake/clang" \
  -DLLD_DIR="$PWD/$LLVM_INSTALL/lib/cmake/lld" \
  -DBUILD_SHARED_LIBS=ON \
  -DHalide_WASM_BACKEND=OFF \
  -DWITH_TESTS=OFF -DWITH_TUTORIALS=OFF -DWITH_PYTHON_BINDINGS=OFF \
  -DWITH_DOCS=OFF -DWITH_UTILS=OFF -DWITH_PACKAGING=ON \
  -DCMAKE_INSTALL_PREFIX="$PWD/$SRC/Halide-$HALIDE_VERSION-arm-64-osx"

echo "Building Halide…"
cmake --build "$HALIDE_BUILD" -j"$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)"
cmake --install "$HALIDE_BUILD" >/dev/null

DYLIB="$SRC/Halide-$HALIDE_VERSION-arm-64-osx/lib/libHalide.$( \
  echo "$HALIDE_VERSION" | cut -d. -f1).0.0.dylib"
if strings -a "$DYLIB" | LC_ALL=C grep -E -m 1 '/Users/[^/]+/|/home/[^/]+/'; then
  echo "error: the Halide toolchain still contains a local build path" >&2
  exit 1
fi
echo
echo "Done. Self-containment check — only libSystem, libz and libc++ should appear below:"
otool -L "$DYLIB"
echo
echo "Halide commit: $HALIDE_COMMIT"
echo "Installed at: $SRC/Halide-$HALIDE_VERSION-arm-64-osx"
echo "tools/publish-halide-toolchain.sh packages and publishes it from there."
