import test from 'node:test'
import assert from 'node:assert/strict'
import { makeDNG } from './raw-fixture.js'

test('synthetic DNG pixel words use the byte order declared by the TIFF header', () => {
  for (const littleEndian of [true, false]) for (const mosaic of [true, false]) {
    const width = 17, height = 19, channels = mosaic ? 1 : 3
    const bytes = makeDNG({ width, height, mosaic, littleEndian })
    const view = new DataView(bytes.buffer)
    assert.equal(view.getUint16(0), littleEndian ? 0x4949 : 0x4d4d)
    const directory = view.getUint32(4, littleEndian), count = view.getUint16(directory, littleEndian)
    let pixels
    for (let i = 0; i < count; i++) {
      const at = directory + 2 + i * 12
      if (view.getUint16(at, littleEndian) === 273) pixels = view.getUint32(at + 8, littleEndian)
    }
    assert.ok(pixels > directory)
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) for (let c = 0; c < channels; c++) {
      const colour = mosaic ? [0, 1, 1, 2][(y % 2) * 2 + x % 2] : c
      const expected = 512 + 1200 + x * 11 + y * 7 + [100, 40, 0][colour]
      assert.equal(view.getUint16(pixels + ((y * width + x) * channels + c) * 2, littleEndian), expected)
    }
  }
})
