#!/usr/bin/env bash
# Release boundary: fail before signing/publishing if repository-only material reached an app.
set -euo pipefail

BUNDLE="${1:?usage: $0 <app-or-plugin-bundle>}"
[[ -d "$BUNDLE" ]] || { echo "error: bundle not found: $BUNDLE" >&2; exit 1; }

failures=0
report() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

while IFS= read -r path; do
  report "repository-only file reached the bundle: $path"
done < <(find "$BUNDLE" \( \
  -iname 'readme*' -o -name '*.swift' -o -name '*.swiftinterface' \
  -o -name '*.swiftmodule' -o -name '*.h' -o -name '*.hpp' -o -name '*.modulemap' \
  -o -name '*.dSYM' -o -name '.DS_Store' -o -name '._*' \
  \) -print)

while IFS= read -r directory; do
  if [[ "${FOTUFILM_SOURCE_BUILD:-0}" == 1 ]]; then
    python3 "$(dirname "$0")/verify-starter-pack.py" "$directory" || report "invalid Starter pack: $directory"
  else
    report "plaintext stock directory reached the bundle: $directory"
  fi
done < <(find "$BUNDLE" -type d -name Stocks -print)

if [[ "${FOTUFILM_SOURCE_BUILD:-0}" == 1 ]]; then
  while IFS= read -r pack; do
    report "sealed pack reached a Starter-only bundle: $pack"
  done < <(find "$BUNDLE" -type f -name '*.fotufilmpack' -print)
fi

# Every engine resource root must carry its configured runtime stock set.
while IFS= read -r coefficient; do
  resources="$(dirname "$coefficient")"
  pack_names=(fotufilm bundled)
  if [[ "${FOTUFILM_SOURCE_BUILD:-0}" == 1 ]]; then
    pack_names=()
    [[ -d "$resources/Stocks" ]] || report "$resources is missing the Starter pack"
  fi
  for name in ${pack_names[@]+"${pack_names[@]}"}; do
    if [[ ! -f "$resources/$name.fotufilmpack" ]]; then
      # SwiftPM owns the recovery prior in its resource bundle, while the containing app owns the
      # sealed packs. Hand-assembled app and plug-in roots keep all three files together.
      if [[ "$resources" == *_FotufilmCore.bundle ]] && \
         find "$BUNDLE" -type f -name "$name.fotufilmpack" -print -quit | grep -q .; then
        continue
      fi
      report "$resources is missing $name.fotufilmpack"
    fi
  done
done < <(find "$BUNDLE" -type f -name rec2020-reflectance-prior.coeff -print)

# Camera JSON is public upstream data. Xcode also emits version.json inside signed App Intents
# metadata directories; it describes the generated metadata format, not repository content.
while IFS= read -r json; do
  [[ ( "${FOTUFILM_SOURCE_BUILD:-0}" == 1 && "$json" == */Stocks/*.json ) || \
     "$json" == */CameraProfiles/*.json || \
     "$json" == */Metadata.appintents/version.json ]] || \
    report "unexpected plaintext JSON reached the bundle: $json"
done < <(find "$BUNDLE" -type f -name '*.json' -print)

while IFS= read -r file; do
  leaked="$(strings -a "$file" | LC_ALL=C grep -E -m 1 \
    '/Users/[^/]+/|/home/[^/]+/|/\.claude/worktrees/' || true)"
  [[ -z "$leaked" ]] || report "local build path in $file: $leaked"
done < <(find "$BUNDLE" -type f -print)

(( failures == 0 )) || exit 1
echo "Audited $BUNDLE: no authoring files, unapproved stock resources, or local build paths."
