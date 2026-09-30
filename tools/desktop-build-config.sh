#!/usr/bin/env bash
# Source from the repository root before building a desktop target. Every build ships the same
# public film profiles; FOTUFILM_SOURCE_BUILD=0 selects the official app identity.
export FOTUFILM_SOURCE_BUILD="${FOTUFILM_SOURCE_BUILD:-1}"

SOURCE_BUILD_FLAGS=()
# An official build can keep the source app's bundle, keychain, and imported-pack identity
# for existing installations.
if [[ "$FOTUFILM_SOURCE_BUILD" == 1 || "${FOTUFILM_USE_SOURCE_IDENTITY:-0}" == 1 ]]; then
  SOURCE_BUILD_FLAGS=(-D FOTUFILM_SOURCE_BUILD)
fi

FOTUFILM_CORE_SOURCE_DIR="${FOTUFILM_CORE_SOURCE_DIR:-$PWD/Sources/FotufilmCore}"
[[ "$FOTUFILM_CORE_SOURCE_DIR" == /* && -f "$FOTUFILM_CORE_SOURCE_DIR/FilmStock.swift" ]] || {
  echo "error: FOTUFILM_CORE_SOURCE_DIR must be an absolute path to a complete FotufilmCore source directory" >&2
  exit 1
}
export FOTUFILM_CORE_SOURCE_DIR
