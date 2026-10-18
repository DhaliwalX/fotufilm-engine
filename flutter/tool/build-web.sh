#!/bin/bash
# Builds the editor for the browser: the Flutter UI compiled to WebAssembly, with the web
# editor's engine bridge bundled beside it at engine/bridge.js. The engine's runtime assets (its
# WASM modules and film packs, from tools/build-wasm.sh) are served at engine/ too: tool/serve-web.mjs
# serves them in place, and `--assets <dir>` copies them in, leaving out the development ones, so
# build/web is the whole site to deploy. FOTUFILM_BASE is the path it is served under (default /).
#
#   tool/build-web.sh [--assets <a browser build's web/public>]
set -euo pipefail
cd "$(dirname "$0")/.."
base="${FOTUFILM_BASE:-/}"
assets=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets) assets="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -f assets/generated/controls.json ]] || tool/prepare.sh
flutter build web --wasm --release --base-href "$base"
(cd ../web && FOTUFILM_BASE="$base" FOTUFILM_ASSETS="$assets" \
  npx vite build --config vite.flutter.config.js --logLevel warn)
if [[ -n "$assets" ]]; then
  # The engine's modules, packs and decoders; not its parity fixtures, tests or the sample scene.
  rsync -a --exclude /parity --exclude /test --exclude /demo-scene.exr \
    --exclude /robots.txt --exclude /sitemap.xml --exclude /site.webmanifest \
    "$assets/" build/web/engine/
fi
echo "Built build/web${assets:+ with the engine from $assets}."
