// The render baseline's browser road: the built WebAssembly engine, driven by the page's own
// orchestration (web/src/engine.js), develops the chart through every output medium of the
// baseline's film and writes each frame as an FSPY record for tools/render-baseline.py.
//
//   node tools/render-baseline-wasm.mjs <inputs> <out>
//
// <inputs> is what RenderBaselineTests.testWriteWasmInputs writes: the chart as scene light
// (float RGBA, linear Rec. 2020) and the committed JPEG decoded to sRGB codes, as a canvas would
// hand them over. Needs web/public built by tools/build-wasm.sh; tools/render-baseline.sh runs it.
import assert from 'node:assert/strict'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const [inputs, out] = process.argv.slice(2)
assert.ok(inputs && out, 'usage: node tools/render-baseline-wasm.mjs <inputs> <out>')

const assets = new URL('../web/public/', import.meta.url)
globalThis.window = {}
globalThis.fetch = async (url) =>
  new Response(await readFile(new URL(url)), {
    headers: { 'Content-Type': 'application/wasm' },
  })
const { default: create } = await import(new URL('fotufilm.mjs', assets))
const { parsePack, pixelSource, SimdDeveloper } = await import('../web/src/engine.js')
const { applyMediumDelta } = await import('../web/src/output-media.js')

const { width, height, stock, media } = JSON.parse(
  await readFile(path.join(inputs, 'inputs.json'), 'utf8'),
)
const sources = {
  scene: new Float32Array((await readFile(path.join(inputs, 'scene.f32'))).buffer.slice(0)),
  jpeg: new Uint8ClampedArray(await readFile(path.join(inputs, 'display.rgba8'))),
}
for (const [name, data] of Object.entries(sources)) {
  assert.equal(data.length, width * height * 4, `${name}: not ${width}x${height} RGBA`)
}

// The film's own pack, and each medium as the page builds it: the delta applied to that pack.
const catalog = JSON.parse(await readFile(new URL('packs/media.json', assets), 'utf8'))
const entry = catalog.find((s) => s.id === stock)
assert.ok(entry, `${stock}: not in packs/media.json`)
const base = (await readFile(new URL(`packs/${stock}.pack`, assets))).buffer.slice(0)
async function packFor(medium) {
  if (medium === entry.default) return base
  const choice = entry.choices.find((c) => c.id === medium)
  assert.ok(choice?.pack, `${stock}: no ${medium} medium in packs/media.json`)
  return applyMediumDelta(base, await readFile(new URL(`packs/${choice.pack}`, assets)))
}

function record(name, values) {
  const nameBytes = Buffer.from(name, 'utf8')
  const header = Buffer.alloc(4 + 4 + nameBytes.length + 12)
  header.write('FSPY', 0, 'ascii')
  header.writeInt32LE(nameBytes.length, 4)
  nameBytes.copy(header, 8)
  header.writeInt32LE((width << 16) | height, 8 + nameBytes.length)
  header.writeInt32LE(0, 12 + nameBytes.length)
  header.writeInt32LE(values.length, 16 + nameBytes.length)
  return Buffer.concat([header, Buffer.from(values.buffer, values.byteOffset, values.byteLength)])
}

await mkdir(out, { recursive: true })
const engine = await create()
for (const medium of media) {
  const pack = parsePack(await packFor(medium))
  for (const [input, data] of Object.entries(sources)) {
    const developer = new SimdDeveloper(engine, pack)
    try {
      const result = await developer.develop(pixelSource({ data, width, height }), {}, undefined,
        undefined, { bitDepth: 16 })
      assert.ok(result?.pixels, `${input}-${medium}: no frame`)
      const { pixels } = result
      const scale = pixels instanceof Float32Array ? 1 : pixels instanceof Uint16Array ? 65535 : 255
      const rgb = new Float32Array(width * height * 3)
      for (let i = 0; i < width * height; ++i) {
        for (let c = 0; c < 3; ++c) rgb[i * 3 + c] = pixels[i * 4 + c] / scale
      }
      await writeFile(path.join(out, `${input}-${medium}.bin`), record(`${input}-${medium}`, rgb))
      console.log(`${input}-${medium}: developed`)
    } finally {
      developer.dispose()
    }
  }
}
