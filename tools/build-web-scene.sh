#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product fotufilm
./.build/release/fotufilm --dump-web-scene web/public/packs/scene
cp THIRD_PARTY_NOTICES.md licenses/FILM-PROFILES.txt licenses/CC-BY-SA-4.0.txt web/public/packs/scene/
python3 - <<'PY'
import gzip, hashlib, json
from pathlib import Path
root = Path('web/public/packs/scene')
data = (root / 'geometry.f32').read_bytes()
catalog = json.loads((root / 'index.json').read_text())
catalog['geometrySHA256'] = hashlib.sha256(data).hexdigest()
(root / 'index.json').write_text(json.dumps(catalog, separators=(',', ':')) + '\n')
(root / 'geometry.spectra').write_bytes(gzip.compress(data, compresslevel=9, mtime=0))
(root / 'geometry.f32').unlink()
print('Scene spectral geometry:', len(data), 'bytes before gzip')
PY
