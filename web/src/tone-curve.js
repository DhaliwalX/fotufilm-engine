// The Output panel's tone curve in the browser, as HostService.toneCurve draws it natively: a
// neutral grey ramp of input codes 0…255, sRGB-encoded as a JPEG holds them, developed as the
// shown photograph is, read back per channel.

/// Steps of the grey ramp, the pixels each step spans, and the strip's rows.
export const TONE_CURVE_STEPS = 256
const STEP_WIDTH = 4
const ROWS = 4

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
