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
  report "plaintext stock directory reached the bundle: $directory"
done < <(find "$BUNDLE" -type d -name Stocks -print)

# Every engine resource root is marked by the recovery prior and must carry both sealed stock sets.
while IFS= read -r coefficient; do
  resources="$(dirname "$coefficient")"
  pack_names=(fotufilm bundled)
  [[ "${FOTUFILM_SOURCE_BUILD:-0}" == 1 ]] && pack_names=(bundled)
  for name in "${pack_names[@]}"; do
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
  [[ "$json" == */CameraProfiles/*.json || \
     "$json" == */Metadata.appintents/version.json ]] || \
    report "unexpected plaintext JSON reached the bundle: $json"
done < <(find "$BUNDLE" -type f -name '*.json' -print)

while IFS= read -r file; do
  leaked="$(strings -a "$file" | LC_ALL=C grep -E -m 1 \
    '/Users/[^/]+/|/home/[^/]+/|/\.claude/worktrees/' || true)"
  [[ -z "$leaked" ]] || report "local build path in $file: $leaked"
done < <(find "$BUNDLE" -type f -print)

(( failures == 0 )) || exit 1
echo "Audited $BUNDLE: no authoring files, plaintext stocks, or local build paths."
