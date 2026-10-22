import test from 'node:test'
import assert from 'node:assert/strict'
import { DPX_TYPE, encodeDPX } from '../../src/dpx.js'
import { encodeTileInto } from '../../src/output-encoding.js'

test('DPX carries 10-bit printing density, big-endian, as CineonDPX writes it', async () => {
  const width = 3
  const height = 2
  const codes = [95, 470, 685, 0, 1023, 2000, 512, 100, 900, 300, 301, 302, 1, 2, 3, 1022, 1021, 1020]
  const pixels = new Uint16Array(width * height * 4)
  for (let p = 0; p < width * height; ++p) {
    for (let c = 0; c < 3; ++c)
      pixels[p * 4 + c] = Math.min(65535, Math.round((codes[p * 3 + c] / 1023) * 65535))
    pixels[p * 4 + 3] = 65535
  }
  const blob = encodeDPX({ pixels, width, height, format: 'Super 35', stock: 'vision250d', frameRate: 24 })
  assert.equal(blob.type, DPX_TYPE)
  const view = new DataView(await blob.arrayBuffer())
  const text = (offset, length) =>
    new TextDecoder().decode(new Uint8Array(view.buffer, offset, length)).replace(/\0.*$/, '')
  assert.equal(view.byteLength, 2048 + width * height * 4)
  assert.equal(text(0, 4), 'SDPX')
  assert.equal(view.getUint32(4), 2048)
  assert.equal(text(8, 8), 'V2.0')
  assert.equal(view.getUint32(16), view.byteLength)
  assert.equal(view.getUint32(24) + view.getUint32(28), 2048)
  assert.equal(view.getUint16(770), 1)
  assert.equal(view.getUint32(772), width)
  assert.equal(view.getUint32(776), height)
  assert.deepEqual([800, 801, 802, 803].map((o) => view.getUint8(o)), [50, 1, 1, 10])
  assert.equal(view.getUint16(804), 1, 'filled method A')
  assert.equal(view.getUint32(808), 2048)
  assert.equal(view.getFloat32(1724), 24)
  assert.equal(text(1680, 32), 'Super 35')
  assert.equal(text(1732, 32), 'vision250d')
  for (let p = 0; p < width * height; ++p) {
    const word = view.getUint32(2048 + p * 4)
    assert.equal(word & 3, 0)
    assert.deepEqual(
      [word >>> 22, (word >>> 12) & 0x3ff, (word >>> 2) & 0x3ff],
      codes.slice(p * 3, p * 3 + 3).map((v) => Math.min(v, 1023)),
      `pixel ${p}`,
    )
  }
})

test('Cineon code values are encoded as the signal they are', () => {
  const signals = [95 / 1023, 445 / 1023, 685 / 1023, 0.98]
  const output = new Float32Array(signals.flatMap((v) => [v, v * 0.9, v * 0.8, 1]))
  const region = { x: 0, y: 0, width: signals.length, height: 1 }
  const tile = { ...region, region }
  const pixels = new Uint16Array(signals.length * 4)
  // An sRGB canvas would take the matrix, the shoulder and the transfer; code values take none.
  encodeTileInto(pixels, signals.length, output, tile, 0, 4, [0, 1, 2], 'srgb', undefined, 0.7, true)
  for (let i = 0; i < signals.length; ++i) {
    for (let c = 0; c < 3; ++c)
      assert.equal(pixels[i * 4 + c], Math.round(output[i * 4 + c] * 65535), `pixel ${i} channel ${c}`)
  }
})
