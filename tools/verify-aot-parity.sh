#!/bin/bash
# Runs every generated AOT variant and compares it against the JIT pipeline it came from.
#
# `swift test` links libHalide and compiles whatever mask it is handed, so the suite never
# executes the .a files the apps ship. This does: it builds the same harness twice — once against
# the generated kernels, once against libHalide — runs all of them, and diffs the results.
#
# One process per variant, so a kernel that asserts when it is first run is reported as a failing
# variant rather than taking the whole run down with it. That is not hypothetical: it is the shape
# of the bug this check exists to catch.
#
# The JIT side pays a Halide compile per variant, so the work is a few seconds of single-threaded
# compile three hundred times over, and a serial run leaves every core but one idle. It is run as
# a pool for the same reason tools/generate-halide-aot.sh is, and safely for the same reason: each
# unit already has a process to itself, so what a run produces cannot depend on how wide the pool
# was. Nothing is shared between units but the read-only fixture. That is checked rather than
# assumed: a serial and a ten-wide sweep were compared record by record and all 300 came back
# byte-identical.
#
# Measured on a ten-performance-core M-series, over the same thirty variants on both roads: 131 s
# serial against 20 s at the default width, 6.6x. Short of the pool width because every unit wants
# the one GPU. The whole script, kernels already stamped, is then 98 s rather than eleven minutes.
#
# It is still a pre-release and CI check, not something to put in front of `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/aot-parity"
# Overridable so two embeddings can be compared without one overwriting the other: the
# metallib road and the source road want separate trees and the same JIT side.
KERNELS="${FOTUFILM_PARITY_KERNELS:-build/halide-macos}"
STOCK="${FOTUFILM_PARITY_STOCK:-example-negative-400}"
SIZE="${FOTUFILM_PARITY_SIZE:-384x216}"
# Set from a measured run: see the summary line the comparison prints. The two roads compile the
# same Halide IR for the same target, so anything above zero here wants explaining rather than
# accommodating — that is still true for source-embedded kernels, which is why this stays at 0
# for anyone comparing those. Metallib kernels do not meet that bar for a reason that has nothing
# to do with correctness: the offline Metal compiler and the driver's own compiler are two
# different pieces of software, and their pow/rsqrt/exp implementations differ at the last couple
# of bits. Measured across all 182 variants: the worst *non-categorical* difference — see
# --categorical-budget below — is 4.77e-6 on a 0..1 output, under half a 16-bit code. 1e-4 leaves
# room for that with margin to spare while still failing on anything that looks like a real
# regression, which this project's own float precision is nowhere near.
TOLERANCE="${FOTUFILM_PARITY_TOLERANCE:-1e-4}"
# How many pixels may land on the wrong side of a rounding boundary before it counts as a failure,
# rather than the boundary case it is. Only 8-bit-output variants hit this at all — a float output
# either differs by a float-scale amount (bounded by TOLERANCE above) or not — and only ever by
# exactly one code. Measured worst case across all 182 variants: 2 pixels of 331,776, on 21
# variants. Double that for margin without opening the door to what an actual regression would
# look like: a wrong stage produces many wrong pixels, not two.
CATEGORICAL_BUDGET="${FOTUFILM_PARITY_CATEGORICAL_BUDGET:-4}"
# The pool width. Matches the kernel generator's default and its reasoning: the performance cores,
# because each unit is one single-threaded Halide compile. FOTUFILM_PARITY_JOBS overrides it for a
# smaller machine, or one already busy — this Mac is also the development machine.
JOBS="${FOTUFILM_PARITY_JOBS:-$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null \
  || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

HALIDE_PREFIX="$(tools/resolve-halide-toolchain.sh)"
# Exported rather than left local: generate-halide-aot.sh below resolves its own Halide the same
# way when it is not told, but as a separate process it would otherwise repeat the resolution
# rather than share this answer — harmless when they agree, a silent mismatch the one time they
# would not (an offline machine mid-fetch, say). Pinning both roads to the one resolved here is
# what the tolerance comment above is actually relying on: two roads, one compiler.
export HALIDE_ROOT="$HALIDE_PREFIX"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos14.0"
mkdir -p "$OUT"

tools/generate-halide-aot.sh macos "$KERNELS"

echo "--- fixture ---"
PACK="$OUT/fixture.fswp"
swift run -c release fotufilm --dump-wasm-pack "$PACK" --stock "$STOCK" --pack-size "$SIZE"

echo "--- building the AOT harness ---"
xcrun clang++ -std=c++17 -O2 -fobjc-arc \
  -isysroot "$SDK" -target "$TARGET" \
  -DFOTUFILM_HALIDE_IOS_AOT=1 \
  -I"$KERNELS" -ISources/FotufilmHalide/include \
  tools/aot-parity.mm Sources/FotufilmHalide/FotufilmHalideIOS.cpp \
  "$KERNELS"/*.a \
  -framework Metal -framework Foundation \
  -o "$OUT/parity-aot"

echo "--- building the JIT harness ---"
xcrun clang++ -std=c++17 -O2 -fobjc-arc \
  -isysroot "$SDK" -target "$TARGET" \
  -DFOTUFILM_HALIDE_ENABLED=1 \
  -I"$HALIDE_PREFIX/include" -ISources/FotufilmHalide/include \
  tools/aot-parity.mm Sources/FotufilmHalide/FotufilmHalideMetal.cpp \
  -L"$HALIDE_PREFIX/lib" -lHalide \
  -Wl,-rpath,"$HALIDE_PREFIX/lib" \
  -framework Metal -framework Foundation \
  -o "$OUT/parity-jit"

COUNT="$("$OUT/parity-aot" --count)"
echo "--- running $COUNT variants on both roads, $JOBS at a time ---"
for road in aot jit; do
  rm -rf "$OUT/$road"
  mkdir -p "$OUT/$road"
done

# Both roads go into one pool rather than a pass each: the reference side spends seconds compiling
# where the shipped side spends milliseconds loading, so splitting them by road would leave the
# pool waiting on the slow half. xargs keeps it full instead.
#
# A variant that aborts leaves no record, which the comparison reports as a missing result for
# that road. That is the reporting path, not an error, so a failing unit must not empty the pool —
# hence the `|| true`, and hence the comparison rather than the exit status being the verdict.
export PARITY_OUT="$OUT" PARITY_PACK="$PACK"
for road in aot jit; do
  for ((index = 0; index < COUNT; ++index)); do
    echo "$road $index"
  done
done | xargs -P "$JOBS" -n 2 sh -c '
  name=$(printf "%03d" "$1")
  "$PARITY_OUT/parity-$0" --pack="$PARITY_PACK" --variant="$1" \
    --out="$PARITY_OUT/$0/$name.bin" >"$PARITY_OUT/$0/$name.log" 2>&1 || true
'

echo "--- comparison ---"
"$OUT/parity-aot" --compare "$OUT/aot" "$OUT/jit" \
  --tolerance="$TOLERANCE" --categorical-budget="$CATEGORICAL_BUDGET"
