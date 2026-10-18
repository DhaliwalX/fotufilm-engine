import { defineConfig } from 'vite'

// The development server for the engine's browser checks: the pages in test/ and the Playwright
// specs (playwright.config.js) load the engine's modules from src/ and its runtime assets from
// public/. The editor builds from flutter/ (flutter/tool/build-web.sh, vite.flutter.config.js).
export default defineConfig({
  // Worker-only imports must not trigger a page reload on the first correction.
  optimizeDeps: { include: ['@bjorn3/browser_wasi_shim'] },
})
