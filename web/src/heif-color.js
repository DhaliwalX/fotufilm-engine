// A HEIC's colour, for the converter movies use (video-color.js): its nclx codes (H.273) as
// WebCodecs names, or the RGB-to-Rec. 2020 matrix and tone curves of a matrix/TRC ICC profile.

const PRIMARIES = { 1: 'bt709', 2: 'bt709', 9: 'bt2020', 12: 'smpte432' }
const TRANSFERS = {
  1: 'bt709', 2: 'iec61966-2-1', 6: 'smpte170m', 8: 'linear', 13: 'iec61966-2-1',
  14: 'bt709', 15: 'bt709', 16: 'pq', 18: 'hlg',
}
const MATRICES = { 1: 'bt709', 2: 'smpte170m', 5: 'bt470bg', 6: 'smpte170m', 9: 'bt2020-ncl' }

// The YUV matrix and range always come from nclx; without one, BT.601 at full range, as libheif
// and ImageIO read Apple's HEICs. Primaries and transfer come from an ICC profile when there is
// one, which the caller applies (`iccToRec2020`).
export function heifColorSpace(nclx, { icc = false } = {}) {
  const code = (table, value, what) => {
    const name = table[value]
    if (!name) throw new Error(`This HEIC file’s ${what} (${value}) is not supported.`)
    return name
  }
  const matrix = nclx ? code(MATRICES, nclx.matrix, 'YUV matrix') : 'smpte170m'
  const fullRange = nclx ? nclx.fullRange : true
  if (icc) return { primaries: 'bt2020', transfer: 'linear', matrix, fullRange }
  return {
    primaries: nclx ? code(PRIMARIES, nclx.primaries, 'colour primaries') : 'bt709',
    transfer: nclx ? code(TRANSFERS, nclx.transfer, 'transfer function') : 'iec61966-2-1',
    matrix,
    fullRange,
  }
}

// D50 (ICC's connection space) to D65, Bradford, and D65 XYZ to Rec. 2020.
const BRADFORD = [0.9555766, -0.0230393, 0.0631636, -0.0282895, 1.0099416, 0.0210077,
  0.0122982, -0.020483, 1.3299098]
const XYZ_TO_2020 = [1.7166512, -0.3556708, -0.2533663, -0.6666844, 1.6164812, 0.0157685,
  0.0176399, -0.0427706, 0.9421031]
const multiply = (a, b) => [0, 1, 2].flatMap((r) => [0, 1, 2].map((c) =>
  a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]))

// A matrix/TRC ICC profile as `{matrix, curves}`: the linear RGB-to-Rec. 2020 matrix (row-major)
// and, per channel, the tone curve from encoded [0, 1] to linear light.
export function iccToRec2020(icc) {
  const view = new DataView(icc.buffer, icc.byteOffset, icc.byteLength)
  if (icc.length < 132 || view.getUint32(36) !== 0x61637370)
    throw new Error('This HEIC file’s colour profile is damaged.')
  if (view.getUint32(16) !== 0x52474220)
    throw new Error('This HEIC file’s colour profile is not RGB.')
  const tags = new Map()
  const count = view.getUint32(128)
  for (let i = 0; i < count && 132 + i * 12 + 12 <= icc.length; i++) {
    const at = 132 + i * 12
    const signature = String.fromCharCode(...icc.subarray(at, at + 4))
    const offset = view.getUint32(at + 4), size = view.getUint32(at + 8)
    if (offset + size <= icc.length) tags.set(signature, { offset, size })
  }
  const fixed = (at) => view.getInt32(at) / 65536
  const xyz = (name) => {
    const tag = tags.get(name)
    if (!tag || tag.size < 20) throw new Error('This HEIC file’s colour profile is not supported.')
    return [0, 1, 2].map((i) => fixed(tag.offset + 8 + i * 4))
  }
  const [r, g, b] = ['rXYZ', 'gXYZ', 'bXYZ'].map(xyz)
  const toXYZ = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
  const matrix = multiply(XYZ_TO_2020, multiply(BRADFORD, toXYZ))
  const curves = ['rTRC', 'gTRC', 'bTRC'].map((name) => curve(view, tags.get(name)))
  return { matrix, curves }
}

function curve(view, tag) {
  if (!tag) throw new Error('This HEIC file’s colour profile is not supported.')
  const at = tag.offset, type = view.getUint32(at)
  if (type === 0x63757276) {
    // 'curv': identity, a gamma, or a table sampled evenly over [0, 1].
    const n = view.getUint32(at + 8)
    if (n === 0) return (x) => x
    if (n === 1) {
      const gamma = view.getUint16(at + 12) / 256
      return (x) => x ** gamma
    }
    const table = Float64Array.from({ length: n }, (_, i) => view.getUint16(at + 12 + i * 2) / 65535)
    return (x) => {
      const p = x * (n - 1), i = Math.min(n - 2, Math.floor(p))
      return table[i] + (table[i + 1] - table[i]) * (p - i)
    }
  }
  if (type === 0x70617261) {
    // 'para': ICC.1 parametric functions 0–4.
    const kind = view.getUint16(at + 8)
    const p = Array.from({ length: [1, 3, 4, 5, 7][kind] ?? 0 },
      (_, i) => view.getInt32(at + 12 + i * 4) / 65536)
    const [gamma, a = 1, b = 0, c = 0, d = 0, e = 0, f = 0] = p
    switch (kind) {
      case 0: return (x) => x ** gamma
      case 1: return (x) => (x >= -b / a ? (a * x + b) ** gamma : 0)
      case 2: return (x) => (x >= -b / a ? (a * x + b) ** gamma + c : c)
      case 3: return (x) => (x >= d ? (a * x + b) ** gamma : c * x)
      case 4: return (x) => (x >= d ? (a * x + b) ** gamma + e : c * x + f)
    }
  }
  throw new Error('This HEIC file’s colour profile is not supported.')
}

// Applies `iccToRec2020` to RGBA samples that hold encoded values, in place. The curves are
// tabulated once: each is smooth, and encoded samples lie within [0, 1].
export function applyICC(pixels, { matrix: m, curves }) {
  const size = 4096
  const tables = curves.map((f) => Float32Array.from({ length: size + 1 }, (_, i) => f(i / size)))
  const linear = (table, v) => {
    const p = Math.max(0, Math.min(1, v)) * size, i = Math.min(size - 1, Math.floor(p))
    return table[i] + (table[i + 1] - table[i]) * (p - i)
  }
  for (let i = 0; i < pixels.length; i += 4) {
    const r = linear(tables[0], pixels[i]), g = linear(tables[1], pixels[i + 1]),
      b = linear(tables[2], pixels[i + 2])
    pixels[i] = m[0] * r + m[1] * g + m[2] * b
    pixels[i + 1] = m[3] * r + m[4] * g + m[5] * b
    pixels[i + 2] = m[6] * r + m[7] * g + m[8] * b
  }
  return pixels
}
