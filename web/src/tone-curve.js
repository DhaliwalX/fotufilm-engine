// The Output panel's tone curve in the browser, as HostService.toneCurve draws it natively: a
// neutral grey ramp of input codes 0…255, sRGB-encoded as a JPEG holds them, developed as the
// shown photograph is, read back per channel, with the photograph's own tones binned on the same
// input axis.

/// Steps of the grey ramp, the pixels each step spans, and the strip's rows.
export const TONE_CURVE_STEPS = 256
const STEP_WIDTH = 4
const ROWS = 4

// Linear Rec. 2020 to linear sRGB, for a float source's tones.
const REC2020_TO_SRGB = [
  1.660491, -0.587641, -0.07285, -0.12455, 1.1329, -0.008349, -0.018151, -0.100579, 1.11873,
]

/// The grey ramp as an 8-bit source (engine.js `pixelSource`): each input code across its step,
/// on every row.
export function toneRamp() {
  const width = TONE_CURVE_STEPS * STEP_WIDTH
  const data = new Uint8ClampedArray(width * ROWS * 4)
  for (let y = 0; y < ROWS; ++y) {
    for (let x = 0; x < width; ++x) {
      const i = (y * width + x) * 4
      data[i] = data[i + 1] = data[i + 2] = Math.floor(x / STEP_WIDTH)
      data[i + 3] = 255
    }
  }
  return {
    width,
    height: ROWS,
    read: (x, y, w, h) => {
      if (x === 0 && y === 0 && w === width && h === ROWS) return data
      const out = new Uint8ClampedArray(w * h * 4)
      for (let row = 0; row < h; ++row)
        out.set(data.subarray(((y + row) * width + x) * 4, ((y + row) * width + x + w) * 4), row * w * 4)
      return out
    },
  }
}

/// The developed ramp's output for each input code, 0…1 per channel: each step's mean inside its
/// edges, so the dither averages out.
export function rampCurve(pixels) {
  const width = TONE_CURVE_STEPS * STEP_WIDTH
  const curve = [[], [], []]
  for (let step = 0; step < TONE_CURVE_STEPS; ++step) {
    const sum = [0, 0, 0]
    let count = 0
    for (let y = 0; y < ROWS; ++y) {
      for (let x = step * STEP_WIDTH + 1; x < (step + 1) * STEP_WIDTH - 1; ++x) {
        const i = (y * width + x) * 4
        for (let c = 0; c < 3; ++c) sum[c] += pixels[i + c]
        count++
      }
    }
    for (let c = 0; c < 3; ++c) curve[c].push(sum[c] / count / 255)
  }
  return { red: curve[0], green: curve[1], blue: curve[2] }
}

const encode = (v) => (v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055)

/// The photograph's pixels at each input code, by the Rec. 709 luma of its sRGB-encoded tones,
/// sampled to about 65,536 pixels. An 8-bit source holds those codes; a float one holds linear
/// Rec. 2020.
export function toneHistogram(source) {
  const { width, height } = source
  const data = source.read(0, 0, width, height)
  const linear = data instanceof Float32Array
  const stride = Math.max(1, Math.floor(Math.sqrt((width * height) / 65536)))
  const histogram = new Array(TONE_CURVE_STEPS).fill(0)
  const m = REC2020_TO_SRGB
  for (let y = 0; y < height; y += stride) {
    for (let x = 0; x < width; x += stride) {
      const i = (y * width + x) * 4
      let r = data[i], g = data[i + 1], b = data[i + 2]
      if (linear) {
        if (!(data[i + 3] > 0)) continue
        const sr = m[0] * r + m[1] * g + m[2] * b
        const sg = m[3] * r + m[4] * g + m[5] * b
        const sb = m[6] * r + m[7] * g + m[8] * b
        r = encode(Math.max(sr, 0))
        g = encode(Math.max(sg, 0))
        b = encode(Math.max(sb, 0))
      } else {
        if (data[i + 3] === 0) continue
        r /= 255
        g /= 255
        b /= 255
      }
      const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
      histogram[Math.round(Math.min(Math.max(luma, 0), 1) * (TONE_CURVE_STEPS - 1))]++
    }
  }
  return histogram
}
