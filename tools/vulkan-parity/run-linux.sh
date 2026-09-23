#!/usr/bin/env bash
# Run inside the Linux Vulkan test container after cross-compiling AOT kernels.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v python3 >/dev/null
OUT="${FOTUFILM_LINUX_OUT:-build/vulkan-parity/linux}"
: > "$OUT/fotufilm_wasm_variants.h"
: > "$OUT/fotufilm_wasm_variants.inc"
LIBRARIES=("$OUT/vk_color.a")
for archive in "$OUT"/*.a; do
    [[ "$archive" == "$OUT/vk_color.a" ]] || LIBRARIES+=("$archive")
done
clang++ -std=c++17 -O2 -I"$OUT" -Ibuild/halide-pr-install/include \
    -ISources/FotufilmHalide/include tools/vulkan-parity/main.cpp web/engine/fotufilm_wasm_cpu.cpp \
    "${LIBRARIES[@]}" -ldl -lpthread -o "$OUT/parity"
export XDG_RUNTIME_DIR=/tmp/fotufilm-vulkan-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
vulkaninfo --summary > "$OUT/device.txt" 2>&1
failed=0
for stock in example-negative-400 example-monochrome-100 example-reversal-64; do
    for test in plain pointwise stock negative negative-mono; do
        log="$OUT/$stock-$test.log"
        "$OUT/parity" "${FOTUFILM_VULKAN_FIXTURES:-build/vulkan-parity/fixtures}/$stock.pack" "$test" 65 49 > "$log" 2>&1 || failed=1
        if grep -qE 'Validation Error|Vulkan \[ERROR\]' "$log"; then failed=1; fi
        python3 - "$log" "$OUT/$stock-$test.json" <<'PY'
import json, sys
lines = [line for line in open(sys.argv[1]) if line.startswith('{')]
result = json.loads(lines[-1]) if lines else {'exact':False,'error':'No result'}
with open(sys.argv[2], 'w') as f: json.dump(result,f,indent=2)
PY
    done
done
exit "$failed"
