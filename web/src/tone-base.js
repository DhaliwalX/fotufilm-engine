import { yieldToBrowser } from './yield.js'
// ToneBaseMeasurement.swift: whole-frame guided tone masks, measured before tiling.
export function boxMean(values, width, height, radius) {
  const sat = new Float64Array((width + 1) * (height + 1))
  for (let y = 0; y < height; y++) {
    let row = 0
    for (let x = 0; x < width; x++) {
      row += values[y * width + x]
      sat[(y + 1) * (width + 1) + x + 1] = sat[y * (width + 1) + x + 1] + row
    }
  }
  const output = new Float64Array(width * height)
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const x0 = Math.max(0, x - radius),
        x1 = Math.min(width - 1, x + radius)
      const y0 = Math.max(0, y - radius),
        y1 = Math.min(height - 1, y + radius)
      const sum =
        sat[(y1 + 1) * (width + 1) + x1 + 1] -
        sat[y0 * (width + 1) + x1 + 1] -
        sat[(y1 + 1) * (width + 1) + x0] +
        sat[y0 * (width + 1) + x0]
      output[y * width + x] = sum / ((x1 - x0 + 1) * (y1 - y0 + 1))
    }
  return output
}
export async function measureTone(source, controls, decode, balance) {
  const { width, height } = source,
    long = Math.max(width, height)
  const gw = Math.min(width, Math.max(1, Math.floor((width * 64 + Math.floor(long / 2)) / long)))
  const gh = Math.min(height, Math.max(1, Math.floor((height * 64 + Math.floor(long / 2)) / long)))
  const sums = new Float64Array(gw * gh),
    counts = new Uint32Array(gw * gh)
  const weights = [0.2627002, 0.6779981, 0.0593017].map(
    (v, i) => (v * balance[i] * 2 ** (controls.ev || 0)) / 0.18,
  )
  for (let top = 0; top < height; top += 32) {
    const rows = Math.min(32, height - top)
    const pixels = decode(source.read(0, top, width, rows))
    for (let y = 0; y < rows; y++)
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4,
          cell = Math.floor(((top + y) * gh) / height) * gw + Math.floor((x * gw) / width)
        const metered =
          weights[0] * Math.max(pixels[i], 0) +
          weights[1] * Math.max(pixels[i + 1], 0) +
          weights[2] * Math.max(pixels[i + 2], 0)
        sums[cell] += Math.log2(Math.max(metered, 1e-6))
        counts[cell]++
      }
    await yieldToBrowser()
  }
  const g = sums.map((v, i) => (counts[i] ? v / counts[i] : 0)),
    radius = Math.min(12, Math.max(gw, gh) - 1)
  const mean = boxMean(g, gw, gh, radius),
    square = boxMean(
      g.map((v) => v * v),
      gw,
      gh,
      radius,
    )
  const a = mean.map((v, i) => {
    const variance = Math.max(0, square[i] - v * v)
    return variance / (variance + 0.25)
  })
  const b = mean.map((v, i) => (1 - a[i]) * v)
  return {
    width: gw,
    height: gh,
    a: Float32Array.from(boxMean(a, gw, gh, radius)),
    b: Float32Array.from(boxMean(b, gw, gh, radius)),
  }
}
export function toneKey(grid, stops, x, y, width, height) {
  if (!grid) return stops
  const gx = Math.min(Math.max(((x + 0.5) * grid.width) / width - 0.5, 0), grid.width - 1)
  const gy = Math.min(Math.max(((y + 0.5) * grid.height) / height - 0.5, 0), grid.height - 1)
  const x0 = Math.min(Math.floor(gx), Math.max(grid.width - 2, 0)),
    y0 = Math.min(Math.floor(gy), Math.max(grid.height - 2, 0))
  const x1 = Math.min(x0 + 1, grid.width - 1),
    y1 = Math.min(y0 + 1, grid.height - 1),
    fx = gx - x0,
    fy = gy - y0
  const sample = (plane) =>
    (1 - fy) * ((1 - fx) * plane[y0 * grid.width + x0] + fx * plane[y0 * grid.width + x1]) +
    fy * ((1 - fx) * plane[y1 * grid.width + x0] + fx * plane[y1 * grid.width + x1])
  return sample(grid.a) * stops + sample(grid.b)
}
