// A transport switch may change spatial response, but never the pointwise colour
// calibration. Check the shipped packs, including films with tungsten references.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { loadPack, SimdDeveloper, pixelSource } from '../web/src/engine.js'

const assets = new URL('../web/public/', import.meta.url)
globalThis.window = {}
globalThis.fetch = async url => new Response(await readFile(new URL(url)), {
  headers: { 'Content-Type': 'application/wasm' },
})
const { default: create } = await import(new URL('fotufilm.mjs', assets))
const module = await create()
const stocks = JSON.parse(await readFile(new URL('packs/index.json', assets)))
const width = 9, height = 7, count = width * height
for (const { id } of stocks.filter(stock => stock.layeredTransport)) {
  const legacy = new SimdDeveloper(module, await loadPack(new URL(`packs/${id}.pack`, assets)))
  const layered = new SimdDeveloper(module, await loadPack(new URL(`packs/${id}.layered.pack`, assets)))
  let maximumError = 0
  try {
    for (const rgb of [[0.18, 0.18, 0.18], [1, 1, 1], [0.4, 0.15, 0.08], [0.01, 0.03, 20]]) {
      const source = pixelSource({ width, height, data: Float32Array.from(
        { length: count * 4 }, (_, i) => i % 4 === 3 ? 1 : rgb[i % 4]) })
      for (const temperature of [3200, 6500, 10000]) {
        const controls = { grain: 0, temperature }
        await legacy.develop(source, controls)
        const expected = module.HEAPF32.slice(legacy.outputPtr / 4, legacy.outputPtr / 4 + count * 3)
        await layered.develop(source, controls)
        const actual = module.HEAPF32.subarray(layered.outputPtr / 4, layered.outputPtr / 4 + count * 3)
        for (let i = 0; i < actual.length; ++i) {
          assert.ok(Number.isFinite(actual[i]), `${id}: nonfinite transport output`)
          maximumError = Math.max(maximumError, Math.abs(actual[i] - expected[i]))
        }
      }
    }
    assert.ok(maximumError < 0.0001, `${id}: transport shifted pointwise colour by ${maximumError}`)
    console.log(`${id}: Legacy/Layered uniform colour maximum error ${maximumError}`)
  } finally { legacy.dispose(); layered.dispose() }
}
