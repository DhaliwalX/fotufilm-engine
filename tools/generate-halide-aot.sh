#!/bin/bash
set -euo pipefail
cd "$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parents[1])' "$0")"

PLATFORM="${1:?usage: $0 <device|simulator|macos|macos-intel> [output-dir]}"
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

OUTPUT="$(python3 tools/aot-release.py output "$PLATFORM" "$OUTPUT")"
STAMP="$OUTPUT/.generated-from"
SCHEDULE_FLAGS="$(python3 tools/aot-release.py flags "$PLATFORM")"

# A public release is keyed solely by engine inputs and the declared compiler recipe, not by a
# locally installed dylib or a consumer app's source. Fetch before resolving any compiler: Xcode
# Cloud needs only these archives, headers and their licence notices.
if [[ -z "${FOTUFILM_AOT_NO_FETCH:-}" && "$SCHEDULE_FLAGS" == '{}' ]]; then
  if python3 tools/aot-release.py cache "$PLATFORM" "$OUTPUT"; then
    echo "Verified cached public AOT kernels ($PLATFORM)."
    exit 0
  fi
  if python3 tools/aot-release.py fetch "$PLATFORM" "$OUTPUT"; then
    exit 0
  else
    STATUS=$?
    # An unavailable release may fall back locally; a checksum or manifest error must not.
    [[ "$STATUS" == 3 ]] || exit "$STATUS"
  fi
fi
if [[ "${FOTUFILM_AOT_REQUIRE_PREBUILT:-0}" == 1 ]]; then
  echo "Matching public AOTs are required. Run the Apple AOT releases workflow on engine main" >&2
  echo "and wait for $(python3 tools/aot-release.py tag "$PLATFORM"). No download token is needed." >&2
  exit 1
fi

HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
HALIDE_PREFIX="$(cd "$HALIDE_PREFIX" && pwd -P)"
echo "Halide: $HALIDE_PREFIX"
COMPILER_HASH="$(shasum -a 256 "$HALIDE_PREFIX/include/Halide.h" "$HALIDE_PREFIX/lib/libHalide.dylib" \
  | shasum -a 256 | cut -d' ' -f1)"
FINGERPRINT="$(python3 tools/aot-release.py key "$PLATFORM") $COMPILER_HASH $TARGET $SCHEDULE_FLAGS $(xcodebuild -version)"

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

# OUTPUT is an absolute, validated generated-only directory (never a repository or home).
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
