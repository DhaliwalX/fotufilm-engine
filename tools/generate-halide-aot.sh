#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:?usage: $0 <device|simulator|macos|macos-intel> [output-dir]}"
RELEASE_REPOSITORY="${FOTUFILM_AOT_REPOSITORY:-DhaliwalX/fotufilm-engine}"
case "$PLATFORM" in
  device)
    OUTPUT="${2:-build/halide-ios-iphoneos}"
    TARGET="arm64-apple-ios18.0"
    GENERATOR_ARGS=()
    ;;
  simulator)
    OUTPUT="${2:-build/halide-ios-iphonesimulator}"
    TARGET="arm64-apple-ios18.0-simulator"
    GENERATOR_ARGS=(--simulator)
    ;;
  macos)
    OUTPUT="${2:-build/halide-macos-arm64}"
    TARGET="arm64-apple-macos14.0"
    GENERATOR_ARGS=(--macos)
    ;;
  macos-intel)
    OUTPUT="${2:-build/halide-macos-x86_64}"
    TARGET="x86_64-apple-macos14.0"
    GENERATOR_ARGS=(--macos-intel)
    ;;
  *)
    echo "usage: $0 <device|simulator|macos|macos-intel> [output-dir]" >&2
    exit 2
    ;;
esac

HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
# Getting the wrong toolchain would not announce itself. The Halide prefix is an input to the
# kernel-inputs hash, so a different one does not fail the build: it silently regenerates all 188
# archives with a different compiler, and the release the hash names no longer matches.
#
# One canonical spelling, because the prefix is part of the fingerprint below: the CI post-clone
# passes an absolute HALIDE_ROOT while the archive's build phase finds the same toolchain by
# relative candidate search, and the two spellings were failing each other's stamp — the archive
# regenerated kernels the fetch had just delivered.
HALIDE_PREFIX="$(cd "$HALIDE_PREFIX" && pwd -P)"
echo "Halide: $HALIDE_PREFIX"

SOURCES=(
  tools/generate_halide_ios.cpp
  Sources/FotufilmHalide/FotufilmHalideShared.h
  Sources/FotufilmHalide/FotufilmHalideMetal.cpp
  Sources/FotufilmHalide/include/FotufilmHalide.h
)
STAMP="$OUTPUT/.generated-from"
FINGERPRINT="$(shasum -a 256 "${SOURCES[@]}" | shasum -a 256 | cut -d' ' -f1)"
SCHEDULE_FLAGS="${FOTUFILM_F16_BLUR:-} ${FOTUFILM_F16_LUT:-} ${FOTUFILM_F16_TETRA:-}"
SCHEDULE_FLAGS="$SCHEDULE_FLAGS ${FOTUFILM_SPLIT_DOWN:-} ${FOTUFILM_METAL_GRAIN:-} ${FOTUFILM_ABLATE:-}"
SCHEDULE_FLAGS="$SCHEDULE_FLAGS ${FOTUFILM_STILL_FAST:-}"
# A metallib archive and a source-embedded one are different bytes from the same generator, so the
# precompile switch has to be in the fingerprint too — otherwise re-running with it flipped against
# the same OUTPUT reads the stamp, sees the generator and schedule unchanged, and serves the wrong
# kind of archive for the request that just asked for it.
SCHEDULE_FLAGS="$SCHEDULE_FLAGS ${FOTUFILM_METAL_PRECOMPILE:-} ${FOTUFILM_METAL_MATH_MODE:-}"
FINGERPRINT="$FINGERPRINT $HALIDE_PREFIX $TARGET $SCHEDULE_FLAGS"

# Prebuilt Halide runtimes can carry the publisher's __FILE__ path. These replacements preserve
# byte lengths and archive offsets, so they are safe for generated objects from either the cache or
# this machine and keep local usernames/worktree names out of every linked product.
redact_generated_paths() {
  local artifacts=() artifact
  [[ -d "$OUTPUT" ]] || return 0
  while IFS= read -r -d '' artifact; do
    artifacts+=("$artifact")
  done < <(find "$OUTPUT" -type f \( -name '*.a' -o -name '*.o' \) -print0)
  if (( ${#artifacts[@]} )); then
    python3 tools/redact-binary-paths.py "${artifacts[@]}"
  fi
}

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$FINGERPRINT" ]]; then
  redact_generated_paths
  echo "Halide kernels are up to date ($PLATFORM)."
  exit 0
fi

# A kernel release published from a development Mac, keyed by kernel-inputs-hash: the same bytes
# this script would generate (one process per variant keeps them machine-independent), fetched in
# seconds instead of minutes. Only attempted when every schedule flag *outside* that hash is at
# its default — a flagged build must be generated, not fetched — and any failure at all falls
# through to generating locally, so an offline machine builds exactly as before.
fetch_kernel_release() {
  [[ -z "${FOTUFILM_AOT_NO_FETCH:-}" ]] || return 1
  [[ -z "${FOTUFILM_F16_BLUR:-}${FOTUFILM_F16_LUT:-}${FOTUFILM_F16_TETRA:-}" ]] || return 1
  [[ -z "${FOTUFILM_SPLIT_DOWN:-}${FOTUFILM_METAL_GRAIN:-}${FOTUFILM_ABLATE:-}" ]] || return 1
  # Releases published by publish-aot-release.sh contain the default Halide 22 precompiled
  # metallibs. Explicit compiler-mode overrides generate locally so a release can never silently
  # substitute archives built under different Metal settings.
  [[ -z "${FOTUFILM_METAL_PRECOMPILE:-}${FOTUFILM_METAL_MATH_MODE:-}" ]] || return 1
  local hash tag asset archive
  hash="$(tools/kernel-inputs-hash.sh "$HALIDE_PREFIX" "$TARGET" 2>/dev/null)" || return 1
  tag="aot-$PLATFORM-${hash:0:16}"
  asset="kernels.tar.gz"
  archive="$OUTPUT-release.tar.gz"
  rm -f "$archive"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$tag" --repo "$RELEASE_REPOSITORY" --pattern "$asset" \
      --output "$archive" 2>/dev/null || { rm -f "$archive"; return 1; }
  else
    local token
    token="${FOTUFILM_AOT_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ -n "$token" ]] || return 1
    local asset_url
    asset_url="$(curl --fail --silent --show-error --connect-timeout 15 --retry 2 \
        -H "Authorization: Bearer $token" \
        "https://api.github.com/repos/$RELEASE_REPOSITORY/releases/tags/$tag" 2>/dev/null \
      | python3 -c 'import json,sys
release = json.load(sys.stdin)
for entry in release.get("assets", []):
    if entry.get("name") == "'"$asset"'":
        print(entry["url"]); break' 2>/dev/null)" || return 1
    [[ -n "$asset_url" ]] || return 1
    curl --fail --location --silent --show-error --connect-timeout 15 --retry 2 \
      -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" \
      "$asset_url" -o "$archive" || { rm -f "$archive"; return 1; }
  fi
  rm -rf "$OUTPUT"
  mkdir -p "$OUTPUT"
  tar xzf "$archive" -C "$OUTPUT" || { rm -rf "$OUTPUT" "$archive"; return 1; }
  rm -f "$archive"
  redact_generated_paths
  # The stamp is this machine's fingerprint, not the publisher's: the toolchain prefix in it is
  # a local path, so it can only be written where it will be checked.
  echo "$FINGERPRINT" > "$STAMP"
  echo "Fetched $PLATFORM kernels from release $tag."
}

if fetch_kernel_release; then
  exit 0
fi

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

HOST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
HOST_TARGET="$(uname -m)-apple-macos"
echo "Building the Halide generator for ${HOST_TARGET}…"
env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET -u MACOSX_DEPLOYMENT_TARGET \
  clang++ -std=c++17 -O2 \
    -isysroot "$HOST_SDK" -target "$HOST_TARGET" \
    -I"$HALIDE_PREFIX/include" -ISources/FotufilmHalide/include \
    tools/generate_halide_ios.cpp \
    -L"$HALIDE_PREFIX/lib" -lHalide \
    -Wl,-rpath,"$HALIDE_PREFIX/lib" \
    -o "$OUTPUT/generate-halide-aot"

# Each variant is an independent single-threaded Halide compile of a few seconds and there are over
# a hundred of them, so a serial run leaves every core but one idle: measured at 7m45s on a
# ten-performance-core M-series. One process per variant, a pool of them at a time.
#
# Per variant rather than per core deliberately — see the comment in generate_halide_ios.cpp. The
# emitted names depend on how many pipelines a process compiled before, so handing each variant a
# fresh process is what keeps the output identical whatever the pool width, and identical between
# this machine and a CI runner with a third of the cores.
#
# Peak RSS is roughly 350 MB per process, so the default costs a few gigabytes; FOTUFILM_AOT_JOBS
# overrides it for a smaller machine, or one already busy with something else.
JOBS="${FOTUFILM_AOT_JOBS:-$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null \
  || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
VARIANTS="$("$OUTPUT/generate-halide-aot" "$OUTPUT" --count)"
echo "Generating $PLATFORM kernels: $VARIANTS variants, $JOBS at a time…"

# xargs returns non-zero if any child did, and -P keeps the pool full rather than waiting on the
# slowest of a fixed split. Failures must stop the script *before* the stamp below is written: a
# half-generated directory that every later run believes is up to date is the worst outcome here.
if ! seq 0 $((VARIANTS - 1)) | xargs -P "$JOBS" -I{} \
    "$OUTPUT/generate-halide-aot" "$OUTPUT" \
    ${GENERATOR_ARGS[@]+"${GENERATOR_ARGS[@]}"} "--variant={}"; then
  echo "A kernel variant failed to compile; not stamping $OUTPUT as generated." >&2
  exit 1
fi

# The measurement, decode and halation-fields pipelines, together in one process.
"$OUTPUT/generate-halide-aot" "$OUTPUT" \
  ${GENERATOR_ARGS[@]+"${GENERATOR_ARGS[@]}"} --extras

cp "$HALIDE_PREFIX/include/HalideBuffer.h" \
   "$HALIDE_PREFIX/include/HalideRuntime.h" \
   "$HALIDE_PREFIX/include/HalideRuntimeMetal.h" \
   "$OUTPUT/"

redact_generated_paths
echo "$FINGERPRINT" > "$STAMP"
echo "Wrote $PLATFORM kernels to $OUTPUT"
