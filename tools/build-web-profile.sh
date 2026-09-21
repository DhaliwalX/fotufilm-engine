#!/bin/bash
# Compile the native settings-to-profile builder for an isolated browser worker.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${FOTUFILM_SWIFT_WASM_SDK:-swift-6.3.3-RELEASE_wasm}"
SWIFT="${FOTUFILM_SWIFT_WASM_COMPILER:-swift}"
if [[ "$SWIFT" == swift && -x /Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift ]]; then
  SWIFT=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift
fi
OUTPUT=web/public/profile
mkdir -p "$OUTPUT/stocks"
"$SWIFT" build -c release --swift-sdk "$SDK" --scratch-path build/swift-wasm \
  --product fotufilm-web-profile -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
BIN="$($SWIFT build -c release --swift-sdk "$SDK" --scratch-path build/swift-wasm --show-bin-path)"
OPT="${FOTUFILM_WASM_OPT:-${EMSDK_ROOT:-build/emsdk}/upstream/bin/wasm-opt}"
"$OPT" --strip-debug --strip-dwarf --strip-producers \
  "$BIN/fotufilm-web-profile.wasm" -o "$OUTPUT/builder.wasm"
cp Sources/FotufilmCore/Resources/rec2020-reflectance-prior.coeff "$OUTPUT/"
# Ship only the public source checkout's stock records, never environment-selected packs.
cp Sources/FotufilmCore/Stocks/*.json "$OUTPUT/stocks/"
cp licenses/FILM-PROFILES.txt licenses/CC-BY-SA-4.0.txt "$OUTPUT/"
# The native catalogue supplies stock-specific availability; the browser does not infer it.
swift build -c release --product fotufilm-web-profile
python3 - <<'PY'
from pathlib import Path
import hashlib, json, subprocess
root = Path('web/public/profile')
definitions = {p.stem: json.loads(p.read_text()) for p in (root / 'stocks').glob('*.json')}
catalogue = subprocess.check_output(['.build/release/fotufilm-web-profile', '--catalogue'],
    input=json.dumps(definitions).encode())
(root / 'catalogue.json').write_bytes(catalogue)
assets = [p for p in root.rglob('*') if p.is_file() and p.name != 'index.json']
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(assets)}
(root / 'index.json').write_text(json.dumps(manifest, separators=(',', ':')) + '\n')
print('Browser profile builder:', (root / 'builder.wasm').stat().st_size, 'bytes')
PY
