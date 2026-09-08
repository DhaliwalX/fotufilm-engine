#!/usr/bin/env bash
# Copies runtime resources. Default desktop builds include all 40 film
# profiles and their license notices. Configured builds use supplied sealed packs.
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="${1:?usage: $0 <resource-directory> [--camera-profiles]}"
INCLUDE_CAMERA_PROFILES=0
[[ $# -le 2 ]] || { echo "usage: $0 <resource-directory> [--camera-profiles]" >&2; exit 2; }
if [[ $# == 2 ]]; then
  [[ "$2" == "--camera-profiles" ]] || {
    echo "usage: $0 <resource-directory> [--camera-profiles]" >&2
    exit 2
  }
  INCLUDE_CAMERA_PROFILES=1
fi

mkdir -p "$DESTINATION"
install -m 0644 LICENSE "$DESTINATION/LICENSE"
install -m 0644 NOTICE "$DESTINATION/NOTICE"
install -m 0644 THIRD_PARTY_NOTICES.md "$DESTINATION/ThirdPartyNotices.txt"
install -m 0644 Sources/FotufilmCore/Resources/rec2020-reflectance-prior.coeff \
  "$DESTINATION/rec2020-reflectance-prior.coeff"

source tools/desktop-build-config.sh
KEY_MATERIAL="$FOTUFILM_PACK_KEY_SOURCE"
PACK_NAMES=(bundled)
if [[ "$FOTUFILM_SOURCE_BUILD" == 1 ]]; then
  PACK_NAMES=()
  rm -rf "$DESTINATION/Stocks"
  rm -f "$DESTINATION/fotufilm.fotufilmpack" "$DESTINATION/bundled.fotufilmpack"
  mkdir -p "$DESTINATION/Stocks"
  while IFS= read -r stock; do
    install -m 0644 "Sources/FotufilmCore/Stocks/$stock.json" "$DESTINATION/Stocks/$stock.json"
  done < <(python3 -c 'import json; print("\n".join(json.load(open("licenses/FILM-PROFILES.json"))))')
  install -m 0644 licenses/FILM-PROFILES.txt "$DESTINATION/Stocks/FILM-PROFILES.txt"
  install -m 0644 licenses/CC-BY-SA-4.0.txt "$DESTINATION/Stocks/CC-BY-SA-4.0.txt"
  python3 tools/verify-film-profiles.py "$DESTINATION/Stocks"
else
  SEALED_DIRECTORY="$FOTUFILM_SEALED_PACKS"
  PACK_NAMES=(fotufilm bundled)
  mkdir -p "$DESTINATION/licenses"
  install -m 0644 licenses/FILM-PROFILES.txt "$DESTINATION/licenses/FILM-PROFILES.txt"
  install -m 0644 licenses/CC-BY-SA-4.0.txt "$DESTINATION/licenses/CC-BY-SA-4.0.txt"
fi
EXPECTED_VAULT_KEY_ID="$(sed -n \
  's/^ *static let vaultKeyID: UInt16 = \([0-9][0-9]*\) *$/\1/p' \
  "$KEY_MATERIAL" | head -1)"
[[ -n "$EXPECTED_VAULT_KEY_ID" ]] || {
  echo "error: could not read vaultKeyID from $KEY_MATERIAL" >&2
  exit 1
}

for name in ${PACK_NAMES[@]+"${PACK_NAMES[@]}"}; do
  pack="$SEALED_DIRECTORY/$name.fotufilmpack"
  [[ -f "$pack" ]] || {
    echo "error: $pack is missing. Regenerate the supplied sealed packs and key material together." >&2
    exit 1
  }
  header="$(od -An -tu1 -j6 -N2 "$pack")"
  read -r key_id_low key_id_high <<< "$header"
  [[ -n "${key_id_low:-}" && -n "${key_id_high:-}" ]] || {
    echo "error: $pack has a truncated container header. Regenerate the supplied sealed packs and key material together." >&2
    exit 1
  }
  pack_key_id=$((key_id_low | (key_id_high << 8)))
  [[ "$pack_key_id" == "$EXPECTED_VAULT_KEY_ID" ]] || {
    printf 'error: %s uses vault key %s, but the app embeds key %s. Regenerate the supplied sealed packs and key material together.\n' \
      "$pack" "$pack_key_id" "$EXPECTED_VAULT_KEY_ID" >&2
    exit 1
  }
  install -m 0644 "$pack" "$DESTINATION/$name.fotufilmpack"
done

if (( INCLUDE_CAMERA_PROFILES )); then
  profiles="$DESTINATION/CameraProfiles"
  rm -rf "$profiles"
  mkdir -p "$profiles"
  while IFS= read -r profile; do
    install -m 0644 "$profile" "$profiles/$(basename "$profile")"
  done < <(find Sources/FotufilmCore/CameraProfiles -maxdepth 1 -type f -name '*.json' -print \
    | LC_ALL=C sort)
  # Required attribution for the verbatim Academy dataset.
  install -m 0644 Sources/FotufilmCore/CameraProfiles/LICENSE "$profiles/LICENSE"
fi
