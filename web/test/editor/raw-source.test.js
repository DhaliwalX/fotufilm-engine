import test from 'node:test'
import assert from 'node:assert/strict'
import { rawSource } from '../../src/raw-source.js'
import { pixelSource, developNormal } from '../../src/engine.js'
import { defaultEdit } from '../../src/editor-state.js'
import { isRawFile, IMAGE_ACCEPT } from '../../src/raw-import.js'

const image = {
  naturalWidth: 3,
  naturalHeight: 2,
  raw: { colors: 1, data: new Uint16Array([1000, 1001, 1002, 2000, 2001, 2002]) },
}
const codes = (source) =>
  Array.from(source.read(0, 0, source.width, source.height))
    .filter((_, i) => i % 4 === 0)
    .map((v) => Math.round(v * 65535))

test('RAW geometry keeps 16-bit codes through every rotate/flip combination', () => {
  const turns = [
    [1000, 1001, 1002, 2000, 2001, 2002],
    [1002, 2002, 1001, 2001, 1000, 2000],
    [2002, 2001, 2000, 1002, 1001, 1000],
    [2000, 1000, 2001, 1001, 2002, 1002],
  ]
  for (let rotation = 0; rotation < 4; rotation++)
    for (const flip of [false, true]) {
      const source = rawSource(image, { ...defaultEdit(), rotation, flip })
      let expected = turns[rotation]
      if (flip)
        expected = Array.from({ length: source.height }, (_, y) =>
          expected.slice(y * source.width, (y + 1) * source.width).reverse(),
        ).flat()
      assert.deepEqual(codes(source), expected)
    }
})
test('RAW crop and tile reads preserve source coordinates and precision', () => {
  const cropped = rawSource(image, {
    ...defaultEdit(),
    crop: [
      [1 / 3, 0],
      [1, 0],
      [1, 1],
      [1 / 3, 1],
    ],
  })
  assert.deepEqual(codes(cropped), [1001, 1002, 2001, 2002])
  const source = rawSource(image, defaultEdit())
  const tiled = [...source.read(0, 0, 3, 1), ...source.read(0, 1, 3, 1)]
  assert.deepEqual(tiled, Array.from(source.read(0, 0, 3, 2)))
  const floats = pixelSource({ width: 3, height: 2, data: source.read(0, 0, 3, 2) })
  assert.ok(floats.read(1, 1, 1, 1) instanceof Float32Array)
  assert.ok(Math.abs(floats.read(1, 1, 1, 1)[0] - 2001 / 65535) < 1e-8)
})
test('linear RAW reaches the engine without sRGB decoding or mutation', async () => {
  const data = new Float32Array([0.18, 0.18, 0.18, 1])
  const source = pixelSource({ width: 1, height: 1, data })
  const result = await developNormal(source, defaultEdit().params)
  assert.ok(result.pixels[0] > 115 && result.pixels[0] < 120)
  assert.deepEqual(data, new Float32Array([0.18, 0.18, 0.18, 1]))
})
test('RAW extensions work with absent or generic file MIME types', () => {
  for (const name of ['photo.NEF', 'photo.CR3', 'photo.DNG', 'photo.RAF', 'photo.ARW']) {
    assert.ok(isRawFile({ name, type: 'application/octet-stream' }))
    assert.ok(IMAGE_ACCEPT.includes(`.${name.split('.').at(-1).toLowerCase()}`))
  }
  assert.equal(isRawFile({ name: 'photo.jpg', type: 'image/jpeg' }), false)
})
