#!/usr/bin/env bash
# Source from the repository root before building a desktop target.
# Custom pack builds supply both inputs through absolute paths.
if [[ "${FOTUFILM_SOURCE_BUILD:-}" == 1 ]]; then
  [[ -z "${FOTUFILM_SEALED_PACKS:-}" ]] || { echo "error: source build cannot include official packs" >&2; exit 1; }
elif [[ -n "${FOTUFILM_PACK_KEY_SOURCE:-}" || -n "${FOTUFILM_SEALED_PACKS:-}" ]]; then
  [[ -f "${FOTUFILM_PACK_KEY_SOURCE:-}" && -d "${FOTUFILM_SEALED_PACKS:-}" ]] || {
    echo "error: set both FOTUFILM_PACK_KEY_SOURCE and FOTUFILM_SEALED_PACKS to existing pack inputs." >&2
    exit 1
  }
  export FOTUFILM_SOURCE_BUILD=0
else
  export FOTUFILM_PACK_KEY_SOURCE="$PWD/shared/FotufilmApp/FilmPackKeyMaterial.swift"
  export FOTUFILM_SOURCE_BUILD=1
fi

SOURCE_BUILD_FLAGS=()
if [[ "$FOTUFILM_SOURCE_BUILD" == 1 ]]; then
  SOURCE_BUILD_FLAGS=(-D FOTUFILM_SOURCE_BUILD)
fi

FOTUFILM_CORE_SOURCE_DIR="${FOTUFILM_CORE_SOURCE_DIR:-$PWD/Sources/FotufilmCore}"
[[ "$FOTUFILM_CORE_SOURCE_DIR" == /* && -f "$FOTUFILM_CORE_SOURCE_DIR/FilmStock.swift" ]] || {
  echo "error: FOTUFILM_CORE_SOURCE_DIR must be an absolute path to a complete FotufilmCore source directory" >&2
  exit 1
}
export FOTUFILM_CORE_SOURCE_DIR
