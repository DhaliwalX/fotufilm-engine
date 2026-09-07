import test from 'node:test'
import assert from 'node:assert/strict'
import {
  cameraKey,
  estimateAsShotKelvin,
  inverse3,
  resolveCameraProfile,
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
