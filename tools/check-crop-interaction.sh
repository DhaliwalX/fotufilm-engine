#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fotufilm-crop-check.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -target arm64-apple-macos14.0 -parse-as-library \
  macos/Tests/CropInteraction.swift \
  Sources/FotufilmImaging/QuadrilateralCrop.swift \
  Sources/FotufilmImaging/UnitCropCoordinates.swift \
  desktop/FotufilmApp/PlatformMedia.swift \
  desktop/FotufilmApp/SessionCropCanvas.swift \
  -o "$test_dir/crop-check"
"$test_dir/crop-check"
