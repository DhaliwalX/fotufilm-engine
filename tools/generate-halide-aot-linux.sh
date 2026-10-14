#!/usr/bin/env bash
# Generates the Linux AOT kernels: the frame variants for CUDA and for Vulkan, side by side, and
# the one Halide runtime both share. Needs a Halide SDK with both backends (HALIDE_ROOT) and the
# Vulkan patches in tools/ (tools/vulkan-parity/README.md).
#   tools/generate-halide-aot-linux.sh [output-dir]      default build/halide-linux-x86_64
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."
HALIDE="${HALIDE_ROOT:?set HALIDE_ROOT to a Halide SDK with CUDA and Vulkan}"
OUTPUT="${1:-build/halide-linux-x86_64}"
JOBS="${FOTUFILM_AOT_JOBS:-$(nproc)}"
mkdir -p "$OUTPUT"
GENERATOR="$OUTPUT/generate-halide-aot"
STAMP="$OUTPUT/.generated-from"

# The kernels are whatever the generator's sources (it and every header it includes), this script,
# the Halide compiler and the generator's FOTUFILM_* overrides made them; when all of those match
# the stamp the set is current.
FINGERPRINT="$(python3 - "$HALIDE" <<'PY'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("aot_release", "tools/aot-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
halide = Path(sys.argv[1])
files = sorted(release.generator_inputs() | {"tools/generate-halide-aot-linux.sh"})
record = {name: release.digest(Path(name).read_bytes()) for name in files}
for name in ("include/Halide.h", "lib/libHalide.so"):
    record[name] = release.digest((halide / name).resolve().read_bytes())
record["flags"] = release.flags()
print(release.digest(json.dumps(record, sort_keys=True).encode()))
PY
)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$FINGERPRINT" ]]; then
  echo "Linux kernels in $OUTPUT are current."
  exit 0
fi
rm -f "$STAMP"

echo "Building the Halide generator…"
"${CXX:-clang++}" -std=c++17 -O2 -I"$HALIDE/include" -ISources/FotufilmHalide/include \
  tools/generate_halide_ios.cpp -L"$HALIDE/lib" -lHalide -Wl,-rpath,"$HALIDE/lib" -lpthread -ldl \
  -o "$GENERATOR"

VARIANTS="$("$GENERATOR" "$OUTPUT" --count)"
for device in cuda vulkan; do
  echo "Generating $device kernels: $VARIANTS variants, $JOBS at a time…"
  seq 0 $((VARIANTS - 1)) | xargs -P "$JOBS" -I{} \
    "$GENERATOR" "$OUTPUT" "--linux-$device" "--prefix=fotufilm_aot_${device}_" "--variant={}"
done
"$GENERATOR" "$OUTPUT" --linux-cuda --prefix=fotufilm_aot_ --extras
cp "$HALIDE/include/HalideBuffer.h" "$HALIDE/include/HalideRuntime.h" \
   "$HALIDE/include/HalideRuntimeCuda.h" "$HALIDE/include/HalideRuntimeVulkan.h" "$OUTPUT/"
echo "$FINGERPRINT" > "$STAMP"
echo "Wrote Linux kernels to $OUTPUT"
