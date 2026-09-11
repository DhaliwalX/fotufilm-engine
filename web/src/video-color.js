import catalog from './generated/video-color.json' with { type: 'json' }

export const VIDEO_ENCODINGS = [
  { id: 'standard', label: 'Standard · use color tags' },
  ...Object.entries(catalog.encodings).map(([id, value]) => ({ id, ...value })),
]
export const decodeCurve = (code, curve) => {
  switch (curve) {
    case 'appleLog':
      return code >= 0.20855531595
        ? 2 ** ((code - 0.69336945) / 0.08550479) - 0.00964052
        : code >= 0
          ? Math.sqrt(code / 47.28711236) - 0.05641088
          : -0.05641088
    case 'sLog3': {
      const c = code * 1023
      return c >= 171.2102946929
        ? 10 ** ((c - 420) / 261.5) * 0.19 - 0.01
        : ((c - 95) * 0.01125) / (171.2102946929 - 95)
    }
    case 'sLog2': {
      const y = (code * 1023 - 64) / 876,
        toe = 0.030001222851889303
      return (
        ((y >= toe
          ? 10 ** ((y - 0.616596 - 0.03) / 0.432699) - 0.037584
          : (y - toe) / 5) *
          0.9 *
          219) /
        155
      )
    }
    case 'fLog':
      return code >= 0.100537775223865
        ? (10 ** ((code - 0.790453) / 0.344676) - 0.009468) / 0.555556
        : (code - 0.092864) / 8.735631
    case 'fLog2':
      return code >= 0.100686685370811
        ? (10 ** ((code - 0.384316) / 0.245281) - 0.064829) / 5.555556
        : (code - 0.092864) / 8.799461
    case 'hlg':
      return (hlg(Math.max(0, Math.min(1, code))) * 0.9) / hlg(0.75)
    default:
      throw new Error(`Unsupported video transfer: ${curve}`)
  }
}
function hlg(v) {
  return v <= 0.5
    ? (v * v) / 3
    : (Math.exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12
}
const identity = [1, 0, 0, 0, 1, 0, 0, 0, 1]
const srgbTo2020 = [
  0.627403896, 0.329283038, 0.043313066, 0.069097289, 0.919540395, 0.011362316,
  0.016391439, 0.088013308, 0.895595253,
]
const p3To2020 = [
  0.753833035, 0.198597369, 0.047569596, 0.045743849, 0.94177722, 0.012478931,
  -0.00121034, 0.017601717, 0.983608623,
]
function standardTransfer(code, transfer) {
  const v = Math.max(0, code)
  if (transfer === 'arib-std-b67') return hlg(Math.min(1, v)) / hlg(0.75)
  if (transfer === 'smpte2084') {
    const p = Math.min(1, v) ** (32 / 2523)
    return (
      ((Math.max(p - 3424 / 4096, 0) /
        Math.max(2413 / 128 - (2392 / 128) * p, 1e-12)) **
        (16384 / 2610) *
        10000) /
      203
    )
  }
  if (transfer === 'linear') return code
  if (transfer === 'iec61966-2-1')
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  if (
    !transfer ||
    ['bt709', 'smpte170m', 'bt2020-10', 'bt2020-12'].includes(transfer)
  )
    return v < 0.081 ? v / 4.5 : ((v + 0.099) / 1.099) ** (1 / 0.45)
  throw new Error(
    `Unsupported standard video transfer: ${transfer}. Choose the recorded input color space.`,
  )
}
export function videoTransform(encoding, colorSpace = {}) {
  if (encoding !== 'standard') {
    const info = catalog.encodings[encoding]
    if (!info) throw new Error('Unknown video input color space.')
    return {
      matrix: info.matrix,
      decode: (v) => decodeCurve(v, info.curve) / 0.9,
    }
  }
  const p = colorSpace.primaries
  const matrix =
    !p || p === 'bt709'
      ? srgbTo2020
      : p === 'bt2020'
        ? identity
        : p === 'smpte432'
          ? p3To2020
          : null
  if (!matrix)
    throw new Error(
      `Unsupported standard video primaries: ${p}. Choose the recorded input color space.`,
    )
  // Validate even a wholly black frame instead of deferring an unsupported tag error.
  standardTransfer(0, colorSpace.transfer)
  return { matrix, decode: (v) => standardTransfer(v, colorSpace.transfer) }
}

// Copy native YUV planes, never canvas-converted RGB: a canvas can tone-map HDR,
// apply a transfer curve, and quantize 10/12-bit log values before we see them.
// Plane offsets and strides are bytes. Planar >8-bit samples store their bits LSB-aligned.
export function decodeVideoPlanes(
  { data, layout, format, width, height, colorSpace = {} },
  encoding,
) {
  const planar = /^(I420|I422|I444)(A)?(P10|P12)?$/.exec(format)
  const nv12 = format === 'NV12',
    rgb = /^(RGBA|RGBX|BGRA|BGRX)$/.test(format)
  if (!planar && !nv12 && !rgb)
    throw new Error(
      `The browser cannot expose ${format || 'this video’s'} pixels without color conversion. Try a different browser or codec.`,
    )
  const depth = planar?.[3] ? Number(planar[3].slice(1)) : 8
  const bytes = depth > 8 ? 2 : 1,
    maximum = 2 ** depth - 1
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  const read = (plane, x, y) => {
    const p = layout[plane]
    const offset = p.offset + y * p.stride + x * bytes
    return bytes === 2 ? view.getUint16(offset, true) : view.getUint8(offset)
  }
  const { matrix: m, decode } = videoTransform(encoding, colorSpace)
  const coefficients = {
    bt709: [0.2126, 0.0722],
    'bt2020-ncl': [0.2627, 0.0593],
    smpte170m: [0.299, 0.114],
    bt470bg: [0.299, 0.114],
  }
  const [kr, kb] = coefficients[colorSpace.matrix || 'bt709'] || []
  if (!rgb && kr === undefined)
    throw new Error(`Unsupported video YUV matrix: ${colorSpace.matrix}.`)
  const full = colorSpace.fullRange === true
  const scale = 2 ** (depth - 8)
  const subX = planar?.[1] === 'I444' ? 1 : 2
  const subY = planar?.[1] === 'I420' || nv12 ? 2 : 1
  const output = new Float32Array(width * height * 4)
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      let r, g, b
      if (rgb) {
        const p = layout[0].offset + y * layout[0].stride + x * 4,
          bgra = format.startsWith('BG')
        r = data[p + (bgra ? 2 : 0)] / 255
        g = data[p + 1] / 255
        b = data[p + (bgra ? 0 : 2)] / 255
      } else {
        const cx = Math.floor(x / subX),
          cy = Math.floor(y / subY)
        const yy =
          (read(0, x, y) - (full ? 0 : 16 * scale)) /
          (full ? maximum : 219 * scale)
        const u =
          ((nv12 ? read(1, cx * 2, cy) : read(1, cx, cy)) - 128 * scale) /
          (full ? maximum : 224 * scale)
        const v =
          ((nv12 ? read(1, cx * 2 + 1, cy) : read(2, cx, cy)) - 128 * scale) /
          (full ? maximum : 224 * scale)
        r = yy + 2 * (1 - kr) * v
        b = yy + 2 * (1 - kb) * u
        g = (yy - kr * r - kb * b) / (1 - kr - kb)
      }
      r = decode(r)
      g = decode(g)
      b = decode(b)
      const i = (y * width + x) * 4
      output[i] = m[0] * r + m[1] * g + m[2] * b
      output[i + 1] = m[3] * r + m[4] * g + m[5] * b
      output[i + 2] = m[6] * r + m[7] * g + m[8] * b
      output[i + 3] = 1
    }
  return output
}
