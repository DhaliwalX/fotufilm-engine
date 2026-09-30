#!/usr/bin/env bash
# Copies runtime resources, including all 46 film profiles and their license
# notices.
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

rm -rf "$DESTINATION/Stocks"
mkdir -p "$DESTINATION/Stocks"
while IFS= read -r stock; do
  install -m 0644 "Sources/FotufilmCore/Stocks/$stock.json" "$DESTINATION/Stocks/$stock.json"
done < <(python3 -c 'import json; print("\n".join(json.load(open("licenses/FILM-PROFILES.json"))))')
install -m 0644 licenses/FILM-PROFILES.txt "$DESTINATION/Stocks/FILM-PROFILES.txt"
install -m 0644 licenses/CC-BY-SA-4.0.txt "$DESTINATION/Stocks/CC-BY-SA-4.0.txt"
python3 tools/verify-film-profiles.py "$DESTINATION/Stocks"

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
