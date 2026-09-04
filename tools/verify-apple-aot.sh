#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--no-exports" ) ]]; then
  echo "usage: $0 <Mach-O binary> [--no-exports]" >&2
  exit 2
fi

BINARY="$1"
if [[ ! -f "$BINARY" ]]; then
  echo "error: AOT verification binary does not exist: $BINARY" >&2
  exit 1
fi

ARCHS="$(xcrun lipo -archs "$BINARY" 2>/dev/null)" || {
  echo "error: AOT verification requires a Mach-O binary: $BINARY" >&2
  exit 1
}

# Release postprocessing strips every name from the symbol table, so nm alone
# cannot see the entry points in a shipped binary. The linker's map file is
# written by the same link that produced the binary, before any stripping, and
# lists only live atoms — a symbol there proves the entry point survived
# -dead_strip and is in the product. Xcode exports TARGET_TEMP_DIR and friends
# into script phases, so the path needs no plumbing.
linkmap_for_arch() {
  local map="${TARGET_TEMP_DIR:-}/${PRODUCT_NAME:-}-LinkMap-${CURRENT_VARIANT:-normal}-$1.txt"
  [[ -n "${TARGET_TEMP_DIR:-}" && -n "${PRODUCT_NAME:-}" && -f "$map" ]] || return 1
  printf '%s\n' "$map"
}

REQUIRED_SYMBOLS=(
  fotufilm_halide_metal_available
  fotufilm_halide_ios_color
  fotufilm_halide_ios_color_float_exact
  fotufilm_halide_ios_monochrome
  fotufilm_halide_ios_monochrome_float_exact
  fotufilm_halide_ios_negative
  fotufilm_halide_ios_slide
  fotufilm_halide_ios_slide_mono
  # The donor family's representative. It is the variant a stock that coats a 4th Color Layer
  # selects for a still, and it is the newest family, so it is the one a half-updated link list
  # drops first — which would not fail the link visibly, it would develop those stocks red.
  fotufilm_halide_ios_negative_donor
)

# Half the kernel set is linked into FotufilmKernels.framework rather than into the app: App Store
# Connect caps a single executable at 500 MB (ITMS-90122) and the whole set does not fit beside the
# app in one Mach-O. An entry point is present if it is defined in *either* binary — the app
# resolves the framework's half dynamically — so look in both before calling one missing.
KERNEL_FRAMEWORK=""
for CANDIDATE in \
    "$(dirname "$BINARY")/Frameworks/FotufilmKernels.framework/FotufilmKernels" \
    "$(dirname "$BINARY")/../Frameworks/FotufilmKernels.framework/FotufilmKernels"; do
  [[ -f "$CANDIDATE" ]] && { KERNEL_FRAMEWORK="$CANDIDATE"; break; }
done

for ARCH in $ARCHS; do
  SYMBOLS="$(xcrun nm -arch "$ARCH" "$BINARY" 2>/dev/null)"
  if [[ -n "$KERNEL_FRAMEWORK" ]]; then
    SYMBOLS="$SYMBOLS
$(xcrun nm -arch "$ARCH" "$KERNEL_FRAMEWORK" 2>/dev/null)"
  fi
  LINKMAP="$(linkmap_for_arch "$ARCH")" || LINKMAP=""
  for SYMBOL in "${REQUIRED_SYMBOLS[@]}"; do
    if grep -Eq "[[:space:]][Tt][[:space:]]+_${SYMBOL}$" <<<"$SYMBOLS"; then
      continue
    fi
    # Live atoms carry an address; dead-stripped ones are listed as <<dead>>.
    if [[ -n "$LINKMAP" ]] && grep -Eq "^0x[0-9A-Fa-f]+.*[[:space:]]_${SYMBOL}$" "$LINKMAP"; then
      continue
    fi
    if [[ -z "$LINKMAP" ]] && ! grep -Eq "[[:space:]][Tt][[:space:]]" <<<"$SYMBOLS"; then
      echo "error: $BINARY ($ARCH) is stripped and no link map was found;" \
           "build with LD_GENERATE_MAP_FILE=YES so AOT linkage can be verified" >&2
      exit 1
    fi
    echo "error: $BINARY ($ARCH) is missing the linked AOT entry point _$SYMBOL" >&2
    exit 1
  done

  if xcrun otool -L -arch "$ARCH" "$BINARY" 2>/dev/null \
      | grep -Eiq '(libHalide|Halide\.framework)'; then
    echo "error: $BINARY ($ARCH) dynamically links Halide; release products must use AOT kernels" >&2
    exit 1
  fi
done

if [[ "${2:-}" == "--no-exports" ]]; then
  EXPORTED="$(xcrun nm -gU "$BINARY" 2>/dev/null | awk '{print $3}' | sort -u || true)"
  if [[ -n "$EXPORTED" ]]; then
    echo "error: $BINARY exports symbols from the application or AOT runtime:" >&2
    echo "$EXPORTED" | sed 's/^/  /' >&2
    exit 1
  fi
fi

echo "Verified AOT-only pipeline: $BINARY ($ARCHS)"
