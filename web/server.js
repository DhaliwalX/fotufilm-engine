// Static host for the built darkroom. Rendering stays in the browser.
import express from 'express'
import { readFileSync } from 'node:fs'
import https from 'node:https'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const port = Number(process.env.PORT || 5757)
const host = process.env.HOST || '0.0.0.0'
const directory = path.resolve(__dirname, process.env.FOTUFILM_DIST || 'dist')
const { FOTUFILM_TLS_CERT: certificate, FOTUFILM_TLS_KEY: key } = process.env
if (!!certificate !== !!key) throw new Error('Provide both FOTUFILM_TLS_CERT and FOTUFILM_TLS_KEY for HTTPS.')
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.')

const app = express()
app.disable('x-powered-by')
app.use(express.static(directory, {
  setHeaders: (res, filePath) => {
    if (filePath.endsWith('.wasm')) res.type('application/wasm')
    if (filePath.endsWith('.pack')) res.type('application/octet-stream')
    // Refresh HTML after a deployment; versioned assets keep their own identities.
    if (filePath.endsWith('.html')) res.setHeader('Cache-Control', 'no-cache')
  },
}))
const server = certificate
  ? https.createServer({ cert: readFileSync(certificate), key: readFileSync(key) }, app)
  : app
server.listen(port, host, () => {
  console.log(`Fotufilm listening on ${certificate ? 'https' : 'http'}://${host}:${port}`)
})
