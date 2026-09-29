import { INGEST_COLOR } from './engine-constants.js'

export const colorSpaceLabel = (space) =>
  space === 'display-p3' ? 'Display P3' : 'sRGB'
export function validateColorSpace(space) {
  if (space !== 'srgb' && space !== 'display-p3')
    throw new Error('Unsupported output color space.')
  return space
}
export const contextColorSpace = (context) =>
  context?.getContextAttributes?.().colorSpace || 'srgb'
export const canvasColorSpace = (canvas) =>
  canvas ? contextColorSpace(canvas.getContext('2d')) : 'srgb'
let preferred
export function preferredCanvasColorSpace() {
  if (preferred) return preferred
  try {
    const canvases = []
    if (typeof document !== 'undefined')
      canvases.push(document.createElement('canvas'))
    if (typeof OffscreenCanvas !== 'undefined')
      canvases.push(new OffscreenCanvas(1, 1))
    preferred =
      canvases.length &&
      canvases.every(
        (canvas) =>
          contextColorSpace(
            canvas.getContext('2d', { colorSpace: 'display-p3' }),
          ) === 'display-p3',
      ) &&
      new ImageData(1, 1, { colorSpace: 'display-p3' }).colorSpace ===
        'display-p3'
        ? 'display-p3'
        : 'srgb'
  } catch {
    preferred = 'srgb'
  }
  return preferred
}
export function colorContext(
  canvas,
  colorSpace = preferredCanvasColorSpace(),
  options = {},
) {
  validateColorSpace(colorSpace)
  const context = canvas.getContext('2d', { ...options, colorSpace })
  if (!context || contextColorSpace(context) !== colorSpace)
    throw new Error(
      `This browser cannot create a ${colorSpaceLabel(colorSpace)} image canvas.`,
    )
  return context
}
export function pixelsCanvas(pixels, width, height, colorSpace = 'srgb') {
  const canvas = document.createElement('canvas')
  Object.assign(canvas, { width, height })
  colorContext(canvas, colorSpace).putImageData(
    new ImageData(pixels, width, height, { colorSpace }),
    0,
    0,
  )
  return canvas
}
// Deep source canvases avoid quantizing a browser-decoded image during geometry.
// Delivery canvases remain explicitly 8-bit; TIFF samples never pass through Canvas.
let deepSource
export function sourceContext(
  canvas,
  colorSpace = preferredCanvasColorSpace(),
) {
  if (deepSource === undefined) {
    try {
      const probe =
        typeof OffscreenCanvas !== 'undefined'
          ? new OffscreenCanvas(1, 1)
          : document.createElement('canvas')
      const context = probe.getContext('2d', {
        colorSpace,
        colorType: 'float16',
        willReadFrequently: true,
      })
      deepSource =
        typeof Float16Array !== 'undefined' &&
        context.getContextAttributes?.().colorType === 'float16' &&
        context.getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-float16' })
          .data instanceof Float16Array
    } catch {
      deepSource = false
    }
  }
  return colorContext(canvas, colorSpace, {
    willReadFrequently: true,
    ...(deepSource ? { colorType: 'float16' } : {}),
  })
}
export function sourcePixels(context, x, y, width, height) {
  const pixelFormat =
    context.getContextAttributes?.().colorType === 'float16'
      ? 'rgba-float16'
      : 'rgba-unorm8'
  return context.getImageData(x, y, width, height, {
    colorSpace: contextColorSpace(context),
    pixelFormat,
  })
}
const decode = (value) =>
  value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
// Canvas samples take at most 65536 values, so decode each once. Float64 tables
// give the same results as decoding every sample, and reading codes avoids
// indexing a Float16Array per sample.
let tables8, tables16
function sampleTables(pixels) {
  if (pixels instanceof Uint8ClampedArray || pixels instanceof Uint8Array) {
    tables8 ??= {
      decoded: Float64Array.from({ length: 256 }, (_, v) => decode(v / 255)),
      value: Float64Array.from({ length: 256 }, (_, v) => v / 255),
    }
    return { ...tables8, codes: pixels }
  }
  if (typeof Float16Array !== 'undefined' && pixels instanceof Float16Array) {
    if (!tables16) {
      const halves = new Float16Array(65536)
      new Uint16Array(halves.buffer).forEach((_, i, codes) => (codes[i] = i))
      const value = Float64Array.from(halves)
      tables16 = { decoded: value.map(decode), value }
    }
    const codes = new Uint16Array(pixels.buffer, pixels.byteOffset, pixels.length)
    return { ...tables16, codes }
  }
  return null
}
// Native ColorScience matrices, exported rather than maintained a second time.
// Canvas samples are unassociated; the engine composites source coverage over black.
export function decodeCanvasPixels(pixels, space) {
  validateColorSpace(space)
  const matrix =
    space === 'display-p3'
      ? INGEST_COLOR.linearDisplayP3ToRec2020
      : INGEST_COLOR.linearSRGBToRec2020
  const output = new Float32Array(pixels.length)
  const [m0, m1, m2, m3, m4, m5, m6, m7, m8] = matrix
  const tables = sampleTables(pixels)
  const { decoded, value } = tables ?? {}
  const codes = tables?.codes
  for (let i = 0; i < pixels.length; i += 4) {
    let a, r, g, b
    if (tables) {
      a = value[codes[i + 3]]
      r = decoded[codes[i]] * a
      g = decoded[codes[i + 1]] * a
      b = decoded[codes[i + 2]] * a
    } else {
      a = pixels[i + 3]
      r = decode(pixels[i]) * a
      g = decode(pixels[i + 1]) * a
      b = decode(pixels[i + 2]) * a
    }
    output[i] = m0 * r + m1 * g + m2 * b
    output[i + 1] = m3 * r + m4 * g + m5 * b
    output[i + 2] = m6 * r + m7 * g + m8 * b
    output[i + 3] = a
  }
  return output
}
