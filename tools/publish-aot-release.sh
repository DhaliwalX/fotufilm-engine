#!/bin/bash
# Publish only generated public engine kernels, never a consumer's build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
REPOSITORY=DhaliwalX/fotufilm-engine
PLATFORMS=("${@:-device}")

[[ -z "$(git status --porcelain)" ]] || {
  echo "Commit the public engine changes before publishing AOTs." >&2; exit 1;
}
[[ "$(git remote get-url origin)" =~ ^(https://github.com/|git@github.com:)DhaliwalX/fotufilm-engine(\.git)?$ ]] || {
  echo "AOTs must be published from the public engine checkout." >&2; exit 1;
}
git fetch --quiet origin main
git merge-base --is-ancestor HEAD origin/main || {
  echo "Merge this engine commit to main before publishing AOTs." >&2; exit 1;
}
[[ "$(python3 tools/aot-release.py flags device)" == '{}' ]] || {
  echo "Unset generator overrides before publishing AOTs." >&2; exit 1;
}
[[ "$(git -C third_party/Halide rev-parse HEAD)" == "$(git ls-tree HEAD third_party/Halide | awk '{print $3}')" \
   && -z "$(git -C third_party/Halide status --porcelain)" ]] || {
  echo "Initialize the clean, pinned Halide submodule before publishing." >&2; exit 1;
}
export HALIDE_ROOT="${HALIDE_ROOT:-$PWD/build/halide-install}"
export FOTUFILM_AOT_NO_FETCH=1
export FOTUFILM_AOT_REQUIRE_PREBUILT=0
command -v gh >/dev/null || { echo "gh CLI is required to publish." >&2; exit 1; }

for PLATFORM in "${PLATFORMS[@]}"; do
  TAG="$(python3 tools/aot-release.py tag "$PLATFORM")"
  if RELEASE="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft,assets 2>/dev/null)"; then
    if [[ "$(jq -r .isDraft <<<"$RELEASE")" == false ]]; then
      jq -e '[.assets[].name] | sort == ["aot-manifest.json", "kernels.tar.gz", "kernels.tar.gz.sha256"]' \
        <<<"$RELEASE" >/dev/null || { echo "$TAG is published but incomplete; refusing to overwrite." >&2; exit 1; }
      echo "$TAG is already published; skipping unchanged inputs."
      continue
    fi
  fi
  case "$PLATFORM" in
    device) SDK=iphoneos; TARGET=arm64-apple-ios18.0 ;;
    simulator) SDK=iphonesimulator; TARGET=arm64-apple-ios18.0-simulator ;;
    macos) SDK=macosx; TARGET=arm64-apple-macos14.0 ;;
    macos-intel) SDK=macosx; TARGET=x86_64-apple-macos14.0 ;;
  esac
  WORK="$PWD/build/aot-releases/$PLATFORM"
  mkdir -p "$WORK"
  OUTPUT="$WORK/kernels"
  tools/generate-halide-aot.sh "$PLATFORM" "$OUTPUT"

  # A real cross-platform link checks the full current bridge against every generated archive.
  # It does not claim GPU execution on a hosted runner.
  xcrun --sdk "$SDK" clang++ -std=c++17 -O2 -dynamiclib \
    -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" -target "$TARGET" \
    -DFOTUFILM_HALIDE_IOS_AOT=1 -I"$OUTPUT" -ISources/FotufilmHalide/include \
    Sources/FotufilmHalide/FotufilmHalideIOS.cpp "$OUTPUT"/*.a \
    -framework Foundation -framework Metal -o "$WORK/aot-link-check.dylib"
  tools/verify-apple-aot.sh "$WORK/aot-link-check.dylib"
  python3 tools/aot-release.py package "$PLATFORM" "$OUTPUT" "$WORK/release"

  # Draft first, so a failed upload never exposes half a release. Existing published tags are
  # immutable. A retry may resume only a draft. Never replace the desktop app's Latest release.
  if [[ -z "${RELEASE:-}" ]]; then
    gh release create "$TAG" --repo "$REPOSITORY" --draft --latest=false \
      --target "$(git rev-parse HEAD)" --title "Apple AOT kernels: $PLATFORM (${TAG##*-})" \
      --notes "Precompiled $PLATFORM kernels from the public engine. The manifest records source, compiler and per-file hashes. Archive checksum, completeness, privacy and AOT-only link checks passed. Downloading requires no token."
  fi
  gh release upload "$TAG" --repo "$REPOSITORY" --clobber \
    "$WORK/release/kernels.tar.gz" "$WORK/release/kernels.tar.gz.sha256" "$WORK/release/aot-manifest.json"
  gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest=false
  echo "Published https://github.com/$REPOSITORY/releases/tag/$TAG"
done
