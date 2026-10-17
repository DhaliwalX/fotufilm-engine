#!/bin/bash
# Builds the editor for the browser: the Flutter UI compiled to WebAssembly, with the web
# editor's engine bridge bundled beside it at engine/bridge.js. The engine's runtime assets (its
# WASM modules and film packs, from tools/build-wasm.sh) are served at engine/ too; see
# tool/serve-web.mjs. FOTUFILM_BASE is the path the site is served under (default /).
set -euo pipefail
cd "$(dirname "$0")/.."
base="${FOTUFILM_BASE:-/}"

[[ -f assets/generated/controls.json ]] || tool/prepare.sh
flutter build web --wasm --release --base-href "$base"
(cd ../web && FOTUFILM_BASE="$base" npx vite build --config vite.flutter.config.js --logLevel warn)
echo "Built build/web. Serve it with tool/serve-web.mjs."
