#!/bin/bash
set -euo pipefail

# Build a public-API consumer, then relocate it and hide its build directory. Only the resource
# bundles beside the executable can satisfy shader loading; no checkout-relative fallback exists.
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [HandwrittenFotufilm.metallib]" >&2
  exit 2
fi
METALLIB="${1:-}"
if [[ -n "$METALLIB" ]]; then
  METALLIB="$(cd "$(dirname "$METALLIB")" && pwd)/$(basename "$METALLIB")"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fotufilm-metal-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/package/Sources/MetalResourceProbe" "$WORK/run"
python3 - "$ROOT" "$WORK/package/Package.swift" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[2]).write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MetalResourceProbe", platforms: [.macOS(.v13)],
    dependencies: [.package(name: "Fotufilm", path: ''' + json.dumps(sys.argv[1]) + ''')],
    targets: [.executableTarget(name: "MetalResourceProbe", dependencies: [
        .product(name: "FotufilmMetal", package: "Fotufilm")])])
''')
PY
cat > "$WORK/package/Sources/MetalResourceProbe/main.swift" <<'SWIFT'
import FotufilmMetal
import Metal

func require<T>(_ value: T?, _ name: String) {
    precondition(value != nil, "could not initialize \(name) from packaged resources")
}
guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("This check requires a Metal device")
}
require(HandwrittenMetalFilmRenderer(), "pointwise")
require(HandwrittenMetalComposedPointwise(device: device), "composed pointwise")
require(HandwrittenMetalFrameEndpoints(device: device), "frame endpoints")
require(HandwrittenMetalFullFrameRenderer(device: device), "full-frame graph")
require(HandwrittenMetalCameraPassThrough(device: device), "camera pass-through")
require(try HandwrittenMetalDigitalDelivery(device: device), "digital delivery")
require(try HandwrittenMetalStillDelivery(device: device), "still delivery")
print("Relocated Metal package consumer passed")
SWIFT

FOTUFILM_DISABLE_HALIDE=1 swift build --package-path "$WORK/package" \
  --scratch-path "$WORK/build" -c release --product MetalResourceProbe
BIN_DIR="$(FOTUFILM_DISABLE_HALIDE=1 swift build --package-path "$WORK/package" \
  --scratch-path "$WORK/build" -c release --show-bin-path)"
cp "$BIN_DIR/MetalResourceProbe" "$WORK/run/"
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$WORK/run/"
done
mv "$WORK/build" "$WORK/build-unavailable"
cd "$WORK/run"
env -u FOTUFILM_METAL_SHADER_ROOT -u FOTUFILM_METAL_LIBRARY_PATH ./MetalResourceProbe

# The same public APIs must also work in release layouts that carry only the precompiled library.
if [[ -n "$METALLIB" ]]; then
  cp "$METALLIB" "$WORK/run/HandwrittenFotufilm.metallib"
  mv "$WORK/run/Fotufilm_FotufilmMetal.bundle" "$WORK/shaders-unavailable.bundle"
  env -u FOTUFILM_METAL_SHADER_ROOT -u FOTUFILM_METAL_LIBRARY_PATH ./MetalResourceProbe
  echo "Precompiled release layout passed without shader sources"
fi
