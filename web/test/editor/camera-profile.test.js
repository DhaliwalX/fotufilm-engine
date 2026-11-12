import test from 'node:test'
import assert from 'node:assert/strict'
import {
  cameraKey,
  estimateAsShotKelvin,
  inverse3,
  resolveCameraProfile,
  scanSource,
} from '../../src/camera-profile.js'

test('camera identity follows the native make/model matching rules', () => {
  assert.equal(cameraKey(' Sony Corporation ', ' SONY ILCE-7CM2 '), cameraKey('Sony', 'ILCE-7CM2'))
  assert.notEqual(cameraKey('Sony', 'ILCE-7CM2'), cameraKey('Sony', 'ILCE-7M2'))
  assert.equal(cameraKey(null, 'ILCE-7CM2'), null)
  assert.equal(resolveCameraProfile({ make: 'Unknown', model: 'Camera' }, { profiles: [] }), null)
})
test('missing or unusable as-shot metadata never invents a camera illuminant', () => {
  const valid = { channels: 3, whiteBalance: [1, 1, 1], cameraToXYZ: [1, 0, 0, 0, 1, 0, 0, 0, 1] }
  const locus = [
    [5500, 0.2, 0.315],
    [6504, 0.22, 0.316],
  ]
  assert.ok(Number.isFinite(estimateAsShotKelvin(valid, locus)))
  for (const change of [
    { channels: 4 },
    { whiteBalance: [0, 1, 1] },
    { cameraToXYZ: Array(9).fill(0) },
    { whiteBalance: [NaN, 1, 1] },
    { whiteBalance: [] },
    { whiteBalance: undefined },
    { cameraToXYZ: [] },
  ])
    assert.equal(estimateAsShotKelvin({ ...valid, ...change }, locus), null)
  assert.equal(inverse3([1, 2, 3]), null)
})

test('a RAW negative says its camera, the white it was decoded on and its decoder matrix', () => {
  const toXYZ = [
    0.412453, 0.35758, 0.180423, 0.212671, 0.71516, 0.072169, 0.019334, 0.119193, 0.950227,
  ]
  const toWide = [
    0.627403896, 0.329283038, 0.043313066, 0.069097289, 0.919540395, 0.011362316, 0.016391439,
    0.088013308, 0.895595253,
  ]
  const product = (a, b) =>
    Array.from({ length: 9 }, (_, i) =>
      [0, 1, 2].reduce((s, k) => s + a[Math.floor(i / 3) * 3 + k] * b[k * 3 + (i % 3)], 0),
    )
  // A decoder's matrix into sRGB, its rows adding up to one, and the camera's daylight levels:
  // what the decoder reports is that matrix as XYZ with each column at its level.
  const mixes = [1.6, -0.45, -0.15, -0.2, 1.5, -0.3, 0.05, -0.55, 1.5]
  const levels = [2.1, 1, 1.6]
  const metadata = {
    make: ' SONY ',
    model: 'ILCE-7CM2',
    channels: 3,
    whiteBalance: levels,
    cameraToXYZ: product(toXYZ, mixes).map((v, i) => v * levels[i % 3]),
  }
  const source = scanSource(metadata)
  assert.deepEqual(source.camera, { make: 'SONY', model: 'ILCE-7CM2' })
  // Balanced on its daylight levels, the camera's white is the matrix's: D65.
  assert.ok(Math.abs(source.white[0] - 0.3127) < 0.0005 && Math.abs(source.white[1] - 0.329) < 0.0005)
  assert.ok(Math.abs(source.kelvin - 6504) < 60)
  const expected = product(toWide, mixes)
  source.matrix.forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 1e-6))
  for (const row of [0, 1, 2])
    assert.ok(Math.abs(source.matrix.slice(row * 3, row * 3 + 3).reduce((a, b) => a + b) - 1) < 1e-6)
  // Another white moves the white it says, not the matrix.
  const warm = scanSource({ ...metadata, whiteBalance: [1.3, 1, 2.6] })
  assert.ok(warm.white[0] > source.white[0] && warm.kelvin < source.kelvin)
  assert.deepEqual(warm.matrix, source.matrix)

  // What a file does not say is left out, never invented.
  assert.deepEqual(scanSource({ ...metadata, make: '', channels: 4 }), {})
  assert.deepEqual(scanSource({ ...metadata, cameraToXYZ: Array(9).fill(0) }), {
    camera: { make: 'SONY', model: 'ILCE-7CM2' },
  })
  const unbalanced = scanSource({ ...metadata, whiteBalance: [0, 1, 1] })
  assert.equal(unbalanced.white, undefined)
  assert.equal(unbalanced.kelvin, undefined)
  assert.deepEqual(unbalanced.matrix, source.matrix)
})
