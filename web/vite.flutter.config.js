import { defineConfig } from 'vite'
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { fileURLToPath, pathToFileURL } from 'node:url'

// The browser engine for the Flutter editor (flutter/): web/src/flutter-bridge.js and the
// backend it imports, bundled beside the Flutter web build as engine/bridge.js. The runtime
// assets it fetches — the engine modules and the packs — are addressed from the base, so they
// are served (or copied) at engine/ as well; flutter/tool/serve-web.mjs serves them from a
// browser build's web/public without copying, and flutter/tool/build-web.sh --assets copies them.
const outDir = fileURLToPath(new URL('../flutter/build/web/engine/', import.meta.url))

// Every runtime asset, packs included, goes into the revision the engine adds to its requests:
// a refreshed page must not pair new JavaScript with an old WASM binary or old spectral tables.
const assets = process.env.FOTUFILM_ASSETS
  ? pathToFileURL(`${process.env.FOTUFILM_ASSETS}/`)
  : new URL('./public/', import.meta.url)
const developmentAssets = ['parity', 'test', 'demo-scene.exr']
const runtimeHash = createHash('sha256')
function hashAssets(directory, prefix = '') {
  for (const name of readdirSync(directory).sort()) {
    if (prefix === '' && developmentAssets.includes(name)) continue
    const url = new URL(name, directory), path = prefix + name
    if (statSync(url).isDirectory()) hashAssets(new URL(name + '/', directory), path + '/')
    else { runtimeHash.update(path + '\0'); runtimeHash.update(readFileSync(url)) }
  }
}
if (existsSync(assets)) hashAssets(assets)

const license = name => readFileSync(new URL(`../licenses/${name}`, import.meta.url), 'utf8')

export default defineConfig({
  base: `${process.env.FOTUFILM_BASE || '/'}engine/`,
  optimizeDeps: { include: ['@bjorn3/browser_wasi_shim'] },
  define: { __FOTUFILM_RUNTIME_REVISION__: JSON.stringify(runtimeHash.digest('hex').slice(0, 20)) },
  publicDir: false,
  plugins: [{
    name: 'browser-third-party-licenses',
    generateBundle() {
      const files = {
        'MEDIABUNNY-MPL-2.0.txt': license('MEDIABUNNY-MPL-2.0.txt'),
        'MEDIABUNNY-SOURCE.txt': 'Mediabunny 1.56.1 by Vanilagy; MPL-2.0; used without modification.\nCorresponding source: https://www.npmjs.com/package/mediabunny/v/1.56.1\nhttps://github.com/Vanilagy/mediabunny/tree/v1.56.1\n',
        'HEVCJS-MIT.txt': license('HEVCJS-MIT.txt'),
        'BROWSER-EXR-MIT.txt': license('BROWSER-EXR-MIT.txt'),
        'HALIDE-MIT.txt': readFileSync(new URL('../tools/webgpu-parity/HALIDE-LICENSE.txt', import.meta.url), 'utf8'),
        'BROWSER-WASI-SHIM-MIT.txt': license('BROWSER-WASI-SHIM-MIT.txt'),
        'SWIFT-APACHE-2.0-RUNTIME.txt': license('SWIFT-APACHE-2.0-RUNTIME.txt'),
        'MATERIAL-SYMBOLS-APACHE-2.0.txt': license('MATERIAL-SYMBOLS-APACHE-2.0.txt'),
      }
      for (const [name, source] of Object.entries(files)) {
        this.emitFile({ type: 'asset', fileName: `licenses/${name}`, source })
      }
    },
  }],
  build: {
    outDir,
    emptyOutDir: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      input: fileURLToPath(new URL('./src/flutter-bridge.js', import.meta.url)),
      output: { entryFileNames: 'bridge.js' },
    },
  },
})
