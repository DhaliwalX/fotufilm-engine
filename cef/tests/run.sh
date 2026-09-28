#!/usr/bin/env bash
# Builds and runs the portable host checks with the system compiler: no CEF, GPU or window, so the
# same checks run on macOS, Linux and Windows (under a POSIX shell).
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/fotufilm-presentation-tests"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -O1 -g -Isrc \
  tests/presentation_tests.cc \
  src/presentation/compositor_core.cc \
  src/presentation/image_layer.cc \
  src/presentation/pooled_presenter.cc \
  -lpthread -o "$out"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -O1 -g -Isrc \
  tests/library_folders_tests.cc src/app/library_folders.cc -o "$out-library"
"$out-library"
"$out"
