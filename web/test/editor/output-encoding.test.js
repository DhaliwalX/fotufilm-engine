import test from 'node:test'
import assert from 'node:assert/strict'
import { WebgpuDeveloper, pixelSource } from '../../src/engine.js'

test('print encoding matches native dithered quantization without a second rounding', async () => {
  const ramp = [-0.02, 0, 0.0001, 0.003, 0.018, 0.1, 0.18, 0.5, 0.9, 1, 2, 10]
  // Golden bytes from native ColorScience and triangularDither, followed by
  // the native UInt8 conversion. Includes black, the transfer toe and HDR shoulder.
  const expected = [
    [0, 0, 0], [1, 0, 0], [0, 0, 0], [9, 10, 9],
    [37, 36, 36], [89, 89, 89], [117, 118, 117], [188, 188, 187],
    [244, 244, 243], [249, 249, 249], [253, 254, 254], [255, 255, 255],
  ].flatMap((rgb) => [...rgb, 255])
  const data = new Float32Array(ramp.flatMap((v) => [v, v, v, 1]))
  const region = { x: 0, y: 0, width: ramp.length, height: 1 }
  // Supply a known linear P3 kernel result to exercise the production delivery path.
  const developer = {
    width: ramp.length, height: 1, seed: 0x46494c4d,
    tiles: [{ ...region, region }], outputStride: 4,
    applyControls() {}, decodeRegion() {}, run: () => 0,
    regionOutput: () => data, outputOffsets: () => [0, 1, 2],
  }
  const source = pixelSource({ width: ramp.length, height: 1, data })
  const result = await WebgpuDeveloper.prototype.develop.call(developer, source, {})
  assert.deepEqual(Array.from(result.pixels), expected)
})
