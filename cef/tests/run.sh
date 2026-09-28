#!/usr/bin/env bash
# Builds and runs the portable host checks with the system compiler: no CEF, GPU or window, so the
# same checks run on macOS, Linux and Windows (under a POSIX shell).
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/fotufilm-host-tests"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -O1 -g -Isrc \
  tests/library_folders_tests.cc src/app/library_folders.cc -o "$out-library"
"$out-library"
