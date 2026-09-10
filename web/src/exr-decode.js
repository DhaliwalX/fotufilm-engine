import { EXRLoader } from 'three/addons/loaders/EXRLoader.js'
import { FloatType, Matrix3, Vector3 } from 'three'

const REC2020 = [0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329]
const REC709 = [0.64, 0.33, 0.3, 0.6, 0.15, 0.06, 0.3127, 0.329]
const identity = () => new Matrix3()
const white = (x, y) => new Vector3(x / y, 1, (1 - x - y) / y)

export function exrToRec2020(chromaticities) {
  const c = chromaticities
    ? ['redX', 'redY', 'greenX', 'greenY', 'blueX', 'blueY', 'whiteX', 'whiteY'].map(
        (k) => chromaticities[k],
      )
    : REC709
  if (!c.every(Number.isFinite) || c[7] <= 0) throw new Error('Invalid EXR chromaticities.')
  if (c.every((v, i) => Math.abs(v - REC2020[i]) < 1e-6)) return identity()
  const p = new Matrix3().set(
    c[0],
    c[2],
    c[4],
    c[1],
    c[3],
    c[5],
    1 - c[0] - c[1],
    1 - c[2] - c[3],
    1 - c[4] - c[5],
  )
  if (Math.abs(p.determinant()) < 1e-10) throw new Error('Degenerate EXR chromaticities.')
  const w = white(c[6], c[7]),
    scale = w.clone().applyMatrix3(p.clone().invert())
  p.multiply(new Matrix3().set(scale.x, 0, 0, 0, scale.y, 0, 0, 0, scale.z))
  const bradford = new Matrix3().set(
    0.8951,
    0.2664,
    -0.1614,
    -0.7502,
    1.7135,
    0.0367,
    0.0389,
    -0.0685,
    1.0296,
  )
  const source = w.clone().applyMatrix3(bradford),
    target = white(0.3127, 0.329).applyMatrix3(bradford)
  const adapt = bradford
    .clone()
    .invert()
    .multiply(
      new Matrix3().set(
        target.x / source.x,
        0,
        0,
        0,
        target.y / source.y,
        0,
        0,
        0,
        target.z / source.z,
      ),
    )
    .multiply(bradford)
  return new Matrix3()
    .set(
      1.716651188,
      -0.355670784,
      -0.253366281,
      -0.666684352,
      1.616481236,
      0.015768546,
      0.017639857,
      -0.042770613,
      0.942103121,
    )
    .multiply(adapt)
    .multiply(p)
}

// Inspect dimensions and image kind before the decoder allocates its output buffer.
function inspectHeader(buffer) {
  const view = new DataView(buffer),
    bytes = new Uint8Array(buffer)
  if (bytes.length < 8 || view.getUint32(0, true) !== 20000630)
    throw new Error('Not an OpenEXR image.')
  const version = view.getUint32(4, true)
  if ((version & 255) !== 2 || version & (0x800 | 0x1000))
    throw new Error('Choose a flat, single-part RGB EXR image.')
  let offset = 8,
    dimensions = false,
    rgb = false
  const string = () => {
    const end = bytes.indexOf(0, offset)
    if (end < 0 || end - offset > 255) throw new Error('Invalid EXR header.')
    const result = new TextDecoder().decode(bytes.subarray(offset, end))
    offset = end + 1
    return result
  }
  while (offset < Math.min(bytes.length, 1024 * 1024)) {
    const name = string()
    if (!name) break
    const type = string(),
      length = view.getUint32(offset, true)
    offset += 4
    const end = offset + length
    if (end > bytes.length) throw new Error('Truncated EXR header.')
    if (name === 'dataWindow' && type === 'box2i' && length === 16) {
      const w = view.getInt32(offset + 8, true) - view.getInt32(offset, true) + 1
      const h = view.getInt32(offset + 12, true) - view.getInt32(offset + 4, true) + 1
      if (w < 1 || h < 1 || w * h > 120_000_000)
        throw new Error('EXR images must be at most 120 megapixels.')
      dimensions = true
    }
    if (name === 'channels' && type === 'chlist') {
      const names = []
      while (offset < end - 1) {
        names.push(string())
        if (
          offset + 16 > end ||
          ![1, 2].includes(view.getInt32(offset, true)) ||
          view.getInt32(offset + 8, true) !== 1 ||
          view.getInt32(offset + 12, true) !== 1
        )
          throw new Error('Choose an RGB half-float or float32 EXR without channel subsampling.')
        offset += 16
      }
      rgb = ['R', 'G', 'B'].every((c) => names.includes(c))
    }
    offset = end
  }
  if (!dimensions || !rgb) throw new Error('Choose an EXR with R, G and B channels.')
}

export function decodeEXR(buffer) {
  inspectHeader(buffer)
  const { data, width, height, header } = new EXRLoader().setDataType(FloatType).parse(buffer)
  const m = exrToRec2020(header.chromaticities).elements
  if (!m.every(Number.isFinite)) throw new Error('Invalid EXR color transform.')
  const samePrimaries = m.every((v, i) => v === (i % 4 === 0 ? 1 : 0))
  const pixels = new Float32Array(width * height * 4)
  // EXRLoader returns bottom-up texture rows; the editor reads top-down image rows.
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const from = ((height - 1 - y) * width + x) * 4,
        to = (y * width + x) * 4
      const r = data[from],
        g = data[from + 1],
        b = data[from + 2]
      if (![r, g, b].every(Number.isFinite))
        throw new Error('EXR contains non-finite scene values.')
      // EXR RGB is associated. Composite over black by retaining RGB, including additive
      // light at zero alpha. No unpremultiply, gamma decode, normalization or clipping.
      pixels[to] = samePrimaries ? r : m[0] * r + m[3] * g + m[6] * b
      pixels[to + 1] = samePrimaries ? g : m[1] * r + m[4] * g + m[7] * b
      pixels[to + 2] = samePrimaries ? b : m[2] * r + m[5] * g + m[8] * b
      if (![pixels[to], pixels[to + 1], pixels[to + 2]].every(Number.isFinite))
        throw new Error('EXR color conversion exceeds float32 range.')
      pixels[to + 3] = 1
    }
  return { pixels, width, height }
}
