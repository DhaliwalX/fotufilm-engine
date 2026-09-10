import test from 'node:test'
import assert from 'node:assert/strict'
import { decodeEXR } from '../../src/exr-decode.js'
import { rawSource } from '../../src/raw-source.js'
import { defaultEdit } from '../../src/editor-state.js'
import { exrFixture } from './exr-fixture.js'

test('float32 EXR preserves negative values, deep shadows, HDR and row order exactly', () => {
  const rgb = new Float32Array([-0.25, 0.18, 64, 0.000001, 1, 1025, -0, 3, 4, 5, 6, 7])
  const { pixels, width, height } = decodeEXR(exrFixture(rgb, 2, 2))
  assert.equal(width, 2)
  assert.equal(height, 2)
  const decoded = pixels.filter((_, i) => i % 4 !== 3)
  assert.deepEqual(new Uint32Array(decoded.buffer), new Uint32Array(rgb.buffer))
  const image = { naturalWidth: width, naturalHeight: height, linear: { data: pixels, colors: 4 } }
  const source = rawSource(image, defaultEdit())
  assert.deepEqual(source.read(0, 0, 2, 2), pixels)
  assert.deepEqual(source.read(1, 1, 1, 1), new Float32Array([5, 6, 7, 1]))
  const turned = rawSource(image, { ...defaultEdit(), rotation: 2 })
  assert.deepEqual(turned.read(0, 0, 1, 1), new Float32Array([5, 6, 7, 1]))
})

test('untagged linear Rec.709 changes primaries without gamma or highlight normalization', () => {
  const { pixels } = decodeEXR(exrFixture([4, 0, 0, 0.18, 0.18, 0.18], 2, 1, null))
  const expected = [4 * 0.6274039, 4 * 0.0690973, 4 * 0.0163914, 1, 0.18, 0.18, 0.18, 1]
  pixels.forEach((value, i) => assert.ok(Math.abs(value - expected[i]) < 1e-6, `${i}: ${value}`))
})

test('malformed files and non-finite scene samples fail explicitly', () => {
  assert.throws(() => decodeEXR(new ArrayBuffer(32)), /Not an OpenEXR/)
  assert.throws(() => decodeEXR(exrFixture([NaN, 1, 1], 1, 1)), /non-finite/)
  assert.throws(() => decodeEXR(exrFixture([1, 1, 1], 1, 1).slice(0, 100)))
})
