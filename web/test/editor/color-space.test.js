import test from 'node:test'
import assert from 'node:assert/strict'
import {
  decodeCanvasPixels,
  validateColorSpace,
} from '../../src/canvas-color.js'
import { INGEST_COLOR } from '../../src/engine-constants.js'
import { encodeTileInto } from '../../src/engine.js'
import { framePalette } from '../../src/print-frame-renderer.js'
import { iccProfile } from '../../src/color-profiles.js'

const tile = {
  x: 0,
  y: 0,
  width: 1,
  height: 1,
  region: { x: 0, y: 0, width: 1, height: 1 },
}
test('P3 source decoding uses native Rec.2020 primaries and retains deep samples and alpha', () => {
  const decoded = decodeCanvasPixels(
    new Float32Array([1, 0, 0, 0.5]),
    'display-p3',
  )
  for (let c = 0; c < 3; c++)
    assert.ok(
      Math.abs(
        decoded[c] - INGEST_COLOR.linearDisplayP3ToRec2020[c * 3] * 0.5,
      ) < 1e-7,
    )
  assert.equal(decoded[3], 0.5)
  const deep = decodeCanvasPixels(
    new Float32Array([0.1234, 0.3456, 0.5678, 1]),
    'display-p3',
  )
  const shallow = decodeCanvasPixels(
    new Uint8ClampedArray([0.1234 * 255, 0.3456 * 255, 0.5678 * 255, 255]),
    'display-p3',
  )
  assert.notDeepEqual(deep, shallow)
  assert.throws(() => validateColorSpace('made-up'), /Unsupported/)
})
test('print delivery preserves P3 values outside sRGB and quantizes directly to 16-bit', () => {
  const p3 = new Uint16Array(4),
    srgb = new Uint16Array(4)
  const linear = new Float32Array([0, 0.5, 0, 1])
  encodeTileInto(p3, 1, linear, tile, 0, 4, [0, 1, 2], 'display-p3')
  encodeTileInto(srgb, 1, linear, tile, 0, 4, [0, 1, 2], 'srgb')
  assert.deepEqual(Array.from(p3), [
    0,
    Math.round((1.055 * 0.5 ** (1 / 2.4) - 0.055) * 65535),
    0,
    65535,
  ])
  assert.ok(srgb[1] > p3[1])
  assert.notEqual(p3[1] % 257, 0)
})
test('P3 frame materials are encoded from the native linear P3 palette', () => {
  const plan = {
    configuration: {
      baseRGB: [0.2, 0.4, 0.6],
      edgeRGB: [0, 0, 0],
      rebateRGB: [1, 1, 1],
    },
    palette: { base: [1, 0, 0] },
  }
  assert.deepEqual(framePalette(plan, 'srgb'), plan.palette)
  const actual = framePalette(plan, 'display-p3')
  actual.base.forEach((value, c) =>
    assert.ok(
      Math.abs(
        value - (1.055 * plan.configuration.baseRGB[c] ** (1 / 2.4) - 0.055),
      ) < 1e-9,
    ),
  )
})
test('generated ICC profiles describe distinct primaries with the same transfer curve', () => {
  function tags(bytes) {
    const view = new DataView(bytes.buffer),
      result = new Map()
    assert.equal(String.fromCharCode(...bytes.slice(36, 40)), 'acsp')
    for (let i = 0; i < view.getUint32(128); i++) {
      const at = 132 + i * 12,
        name = String.fromCharCode(...bytes.slice(at, at + 4))
      const start = view.getUint32(at + 4),
        count = view.getUint32(at + 8)
      result.set(name, bytes.slice(start, start + count))
    }
    return result
  }
  const p3 = tags(iccProfile('display-p3')),
    srgb = tags(iccProfile('srgb'))
  assert.notDeepEqual(p3.get('rXYZ'), srgb.get('rXYZ'))
  assert.deepEqual(p3.get('rTRC'), srgb.get('rTRC'))
  assert.throws(() => iccProfile('made-up'), /Unsupported/)
})
