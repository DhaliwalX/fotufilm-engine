// Compare the browser capture-light table with the native engine across film types
// and the entire temperature range. Runs during every complete WASM build.
import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'
import { integrateSceneLight } from '../web/src/scene-light-math.js'

const root = fileURLToPath(new URL('../', import.meta.url))
const catalog = JSON.parse(readFileSync(join(root, 'web/public/packs/scene/index.json')))
const bytes = gunzipSync(readFileSync(join(root, 'web/public/packs/scene/geometry.spectra')))
const geometry = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.length / 4)
const folder = mkdtempSync(join(tmpdir(), 'fotufilm-scene-test-'))
let peak = 0
try {
  for (const stock of ['gold200', 'vision500t', 'hp5plus400', 'c200', 'ektachromee100'])
    for (const kelvin of [1000, 2000, 3200, 4250, 4500, 4750, 5060, 6504, 12000, 25000]) {
      const path = join(folder, 'native.f32')
      execFileSync(join(root, '.build/release/fotufilm'), [
        '--dump-scene-exposure',
        path,
        '--stock',
        stock,
        '--scene-kelvin',
        String(kelvin),
      ])
      const referenceBytes = readFileSync(path)
      const reference = new Float32Array(
        referenceBytes.buffer,
        referenceBytes.byteOffset,
        referenceBytes.length / 4,
      )
      const actual = integrateSceneLight(catalog, geometry, stock, kelvin)
      assert.equal(actual.length, reference.length)
      for (let i = 0; i < actual.length; i++)
        peak = Math.max(peak, Math.abs(actual[i] - reference[i]) / (1 + Math.abs(reference[i])))
    }
  console.log('Native/browser scene-light maximum relative error:', peak)
  assert.ok(peak < 2e-5, `Scene exposure error ${peak}`)
} finally {
  rmSync(folder, { recursive: true, force: true })
}
