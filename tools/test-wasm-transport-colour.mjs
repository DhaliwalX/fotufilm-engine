// Layered Transport adds the light each record returns to its direct capture, so a uniform field
// stays even and gains light against Legacy instead of losing it.
// Check the shipped packs, including films with tungsten references and preflash.
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
  let maximumGain = 0
  try {
    for (const rgb of [[0.18, 0.18, 0.18], [1, 1, 1], [0.4, 0.15, 0.08], [0.01, 0.03, 20]]) {
      const source = pixelSource({ width, height, data: Float32Array.from(
        { length: count * 4 }, (_, i) => i % 4 === 3 ? 1 : rgb[i % 4]) })
      // Preflash exposes the film once, however many components the transport splits it into.
      for (const [temperature, cameraPreflash] of [[3200, 0], [6500, 0], [10000, 0], [6500, 0.02]]) {
        const controls = { grain: 0, temperature, cameraPreflash }
        await legacy.develop(source, controls)
        const expected = module.HEAPF32.slice(legacy.outputPtr / 4, legacy.outputPtr / 4 + count * 3)
        await layered.develop(source, controls)
        const actual = module.HEAPF32.subarray(layered.outputPtr / 4, layered.outputPtr / 4 + count * 3)
        // The output is planar: three width×height planes.
        for (let i = 0; i < actual.length; ++i) {
          assert.ok(Number.isFinite(actual[i]), `${id}: nonfinite transport output`)
          const first = actual[i - (i % count)]
          assert.ok(Math.abs(actual[i] - first) < 0.00005, `${id}: uneven uniform field`)
        }
        const gain = [0, count, 2 * count].reduce((sum, c) => sum + actual[c] - expected[c], 0)
        // Crosstalk lets one record's return dim another channel a little (false-colour films).
        assert.ok(gain > -1 / 255, `${id}: transport darkened ${rgb} by ${-gain}`)
        maximumGain = Math.max(maximumGain, gain)
      }
    }
    console.log(`${id}: Layered uniform fields even, gaining at most ${maximumGain}`)
  } finally { legacy.dispose(); layered.dispose() }
}
