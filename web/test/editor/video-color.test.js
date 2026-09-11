import { test } from 'node:test'
import assert from 'node:assert/strict'
import catalog from '../../src/generated/video-color.json' with { type: 'json' }
import {
  decodeCurve,
  decodeVideoPlanes,
  videoTransform,
  VIDEO_ENCODINGS,
} from '../../src/video-color.js'
import { defaultEdit, parseEdit } from '../../src/editor-state.js'

for (const [id, entry] of Object.entries(catalog.encodings)) {
  test(`${id}: browser curve matches native Swift through toe and HDR values`, () => {
    catalog.codes.forEach((code, index) => {
      const expected = entry.reference[index],
        actual = decodeCurve(code, entry.curve)
      assert.ok(
        Math.abs(actual - expected) < Math.max(2e-6, Math.abs(expected) * 4e-6),
        `${code}: ${actual} != ${expected}`,
      )
    })
    for (let row = 0; row < 3; row++)
      assert.ok(
        Math.abs(
          entry.matrix.slice(row * 3, row * 3 + 3).reduce((a, b) => a + b) - 1,
        ) < 1e-12,
      )
  })
}
test('every Mac encoding is selectable and saved video settings round trip', () => {
  assert.equal(VIDEO_ENCODINGS.length, 10)
  const edit = {
    ...defaultEdit(),
    video: { encoding: 'flog2C', trimStart: 1.2, trimEnd: 2.4, audio: false },
  }
  assert.deepEqual(parseEdit(JSON.stringify({ version: 1, edit }), []), edit)
  delete edit.video
  assert.deepEqual(
    parseEdit(JSON.stringify({ version: 1, edit }), []).video,
    defaultEdit().video,
  )
  edit.video = {
    encoding: 'unsupported',
    trimStart: 0,
    trimEnd: null,
    audio: true,
  }
  assert.throws(
    () => parseEdit(JSON.stringify({ version: 1, edit }), []),
    /video settings/,
  )
})
test('10-bit planar decoding respects padding, range, and sub-byte highlight detail', () => {
  const data = new Uint8Array(64),
    view = new DataView(data.buffer)
  const layout = [
    { offset: 4, stride: 12 },
    { offset: 32, stride: 4 },
    { offset: 40, stride: 4 },
  ]
  for (let y = 0; y < 2; y++)
    for (let x = 0; x < 2; x++)
      view.setUint16(4 + y * 12 + x * 2, 800 + x, true)
  view.setUint16(32, 512, true)
  view.setUint16(40, 512, true)
  const out = decodeVideoPlanes(
    {
      data,
      layout,
      format: 'I420P10',
      width: 2,
      height: 2,
      colorSpace: { matrix: 'bt709', fullRange: false },
    },
    'appleLog',
  )
  assert.ok(out[0] > 1)
  assert.ok(out[4] > out[0])
  assert.ok(
    Math.abs(out[0] - decodeCurve((800 - 64) / 876, 'appleLog') / 0.9) < 1e-6,
  )
  assert.equal(out[0], out[8])
})
test('NV12 legal black/white and full-range RGB use their declared transfer', () => {
  const output = decodeVideoPlanes(
    {
      data: new Uint8Array([16, 235, 16, 235, 128, 128]),
      layout: [
        { offset: 0, stride: 2 },
        { offset: 4, stride: 2 },
      ],
      format: 'NV12',
      width: 2,
      height: 2,
      colorSpace: {
        matrix: 'bt709',
        transfer: 'bt709',
        primaries: 'bt709',
        fullRange: false,
      },
    },
    'standard',
  )
  assert.equal(output[0], 0)
  assert.ok(Math.abs(output[4] - 1) < 1e-6)
  const rgb = decodeVideoPlanes(
    {
      data: new Uint8Array([255, 0, 0, 255]),
      layout: [{ offset: 0, stride: 4 }],
      format: 'BGRA',
      width: 1,
      height: 1,
      colorSpace: { transfer: 'iec61966-2-1' },
    },
    'standard',
  )
  assert.ok(rgb[2] > rgb[0] && rgb[2] > rgb[1])
})
test('standard HDR white is normalized and unsupported color contracts fail explicitly', () => {
  assert.ok(
    Math.abs(
      videoTransform('standard', {
        transfer: 'arib-std-b67',
        primaries: 'bt2020',
      }).decode(0.75) - 1,
    ) < 1e-12,
  )
  assert.ok(
    Math.abs(
      videoTransform('standard', {
        transfer: 'smpte2084',
        primaries: 'bt2020',
      }).decode(0.580688881) - 1,
    ) < 1e-6,
  )
  assert.throws(
    () => videoTransform('standard', { transfer: 'unknown' }),
    /Unsupported/,
  )
  assert.throws(
    () => decodeVideoPlanes({ format: null }, 'appleLog'),
    /without color conversion/,
  )
})
