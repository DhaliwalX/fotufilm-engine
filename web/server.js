// Static host for the built darkroom. The engine runs in the browser now — there is no
// simulate endpoint to proxy an upload to, and no native binary to shell out to.
import express from 'express'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const PORT = process.env.PORT || 5757

const app = express()

// Emscripten serves the module as .mjs and the kernels as .wasm; both need their real types or
// the browser refuses to instantiate them.
app.use(express.static(path.join(__dirname, 'dist'), {
  setHeaders: (res, filePath) => {
    if (filePath.endsWith('.wasm')) res.type('application/wasm')
    if (filePath.endsWith('.pack')) res.type('application/octet-stream')
  },
}))

app.listen(PORT, () => {
  console.log(`fotufilm on http://localhost:${PORT}`)
})
