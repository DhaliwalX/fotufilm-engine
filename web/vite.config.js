import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync, readdirSync, statSync, existsSync, rmSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'

// Include every exported runtime asset, including packs: an HTML refresh must
// not pair new JavaScript with an old WASM binary or old spectral tables.
const runtimeHash = createHash('sha256')
function hashAssets(directory, prefix = '') {
  for (const name of readdirSync(directory).sort()) {
    if (prefix === '' && name === 'parity') continue
    const url = new URL(name, directory), path = prefix + name
    if (statSync(url).isDirectory()) hashAssets(new URL(name + '/', directory), path + '/')
    else { runtimeHash.update(path + '\0'); runtimeHash.update(readFileSync(url)) }
  }
}
if (existsSync(new URL('./public/', import.meta.url))) hashAssets(new URL('./public/', import.meta.url))
const runtimeRevision = runtimeHash.digest('hex').slice(0, 20)
let parityOutput

export default defineConfig({
  define: { __FOTUFILM_RUNTIME_REVISION__: JSON.stringify(runtimeRevision) },
  plugins: [react(), {
    name: 'omit-parity-probes',
    apply: 'build',
    configResolved(config) { parityOutput = resolve(config.root, config.build.outDir, 'parity') },
    closeBundle() { rmSync(parityOutput, { recursive: true, force: true }) },
  }, {
    name: 'browser-third-party-licenses',
    generateBundle() {
      this.emitFile({ type: 'asset', fileName: 'licenses/MEDIABUNNY-MPL-2.0.txt',
        source: readFileSync(new URL('../licenses/MEDIABUNNY-MPL-2.0.txt', import.meta.url), 'utf8') })
      this.emitFile({ type: 'asset', fileName: 'licenses/MEDIABUNNY-SOURCE.txt',
        source: 'Mediabunny 1.56.1 by Vanilagy; MPL-2.0; used without modification.\nCorresponding source: https://www.npmjs.com/package/mediabunny/v/1.56.1\nhttps://github.com/Vanilagy/mediabunny/tree/v1.56.1\n' })
      this.emitFile({ type: 'asset', fileName: 'licenses/HEVCJS-MIT.txt',
        source: readFileSync(new URL('../licenses/HEVCJS-MIT.txt', import.meta.url), 'utf8') })
      this.emitFile({ type: 'asset', fileName: 'licenses/BROWSER-EXR-MIT.txt',
        source: readFileSync(new URL('../licenses/BROWSER-EXR-MIT.txt', import.meta.url), 'utf8') })
      this.emitFile({ type: 'asset', fileName: 'licenses/HALIDE-MIT.txt',
        source: readFileSync(new URL('../tools/webgpu-parity/HALIDE-LICENSE.txt', import.meta.url), 'utf8') })
    },
  }],
  // The published site serves the demo under a sub-path, and everything the app fetches at
  // runtime — the two engine modules and the packs — is addressed from import.meta.env.BASE_URL
  // rather than from the origin. Unset in development, where the demo is the whole site.
  base: process.env.FOTUFILM_BASE || '/',
  // The engine is an Emscripten build in public/, fetched at runtime rather than bundled, so
  // nothing here needs to resolve it. There is no API to proxy: the film develops in the tab.
  build: {
    // The spectral packs are already binary and already large; inlining would only bloat the JS.
    assetsInlineLimit: 0,
  },
})
