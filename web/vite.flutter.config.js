import { defineConfig } from 'vite'
import { fileURLToPath } from 'node:url'

// The browser engine for the Flutter editor (flutter/): web/src/flutter-bridge.js and the
// backend it imports, bundled beside the Flutter web build as engine/bridge.js. The runtime
// assets it fetches — the engine modules and the packs — are addressed from the base, so they
// are served (or copied) at engine/ as well; flutter/tool/serve-web.mjs serves them from a
// browser build's web/public without copying.
const outDir = fileURLToPath(new URL('../flutter/build/web/engine/', import.meta.url))

export default defineConfig({
  base: `${process.env.FOTUFILM_BASE || '/'}engine/`,
  optimizeDeps: { include: ['@bjorn3/browser_wasi_shim'] },
  publicDir: false,
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
