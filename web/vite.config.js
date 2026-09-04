import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
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
