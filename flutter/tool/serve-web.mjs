#!/usr/bin/env node
// Serves the browser build (tool/build-web.sh) for development: build/web, with engine/ falling
// back to a browser build's runtime assets so the packs are not copied.
//
//   node tool/serve-web.mjs [--port 8090] [--assets ../web/public]
//
// It sends the cross-origin isolation headers, so Flutter's renderer can use threads.
import { createServer } from 'node:http'
import { createReadStream, statSync } from 'node:fs'
import { extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const args = process.argv.slice(2)
const option = (name, fallback) => {
  const at = args.indexOf(`--${name}`)
  return at >= 0 ? args[at + 1] : fallback
}
const here = fileURLToPath(new URL('..', import.meta.url))
const site = resolve(here, 'build/web')
const assets = resolve(here, option('assets', process.env.FOTUFILM_WEB_ASSETS || '../web/public'))
const port = Number(option('port', 8090))

const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json', '.css': 'text/css',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.otf': 'font/otf',
  '.ttf': 'font/ttf', '.exr': 'image/x-exr', '.txt': 'text/plain; charset=utf-8',
}

function file(path) {
  try {
    return statSync(path).isFile() ? path : null
  } catch {
    return null
  }
}

createServer((request, response) => {
  const path = normalize(decodeURIComponent(new URL(request.url, 'http://x').pathname))
  if (path.includes('..')) return response.writeHead(400).end()
  let found = file(join(site, path)) ?? (path === '/' ? file(join(site, 'index.html')) : null)
  if (!found && path.startsWith('/engine/')) found = file(join(assets, path.slice('/engine/'.length)))
  if (!found) return response.writeHead(404).end('Not found')
  response.writeHead(200, {
    'Content-Type': types[extname(found)] || 'application/octet-stream',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cache-Control': 'no-cache',
  })
  createReadStream(found).pipe(response)
}).listen(port, '127.0.0.1', () =>
  console.log(`Fotufilm for the browser at http://127.0.0.1:${port}/ (assets: ${assets})`))
