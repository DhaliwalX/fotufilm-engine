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
// Native ColorScience matrices, exported rather than maintained a second time.
// Canvas samples are unassociated; the engine composites source coverage over black.
export function decodeCanvasPixels(pixels, space) {
  validateColorSpace(space)
  const matrix =
    space === 'display-p3'
      ? INGEST_COLOR.linearDisplayP3ToRec2020
      : INGEST_COLOR.linearSRGBToRec2020
  const output = new Float32Array(pixels.length)
  const maximum =
    pixels instanceof Uint8ClampedArray || pixels instanceof Uint8Array
      ? 255
      : 1
  for (let i = 0; i < pixels.length; i += 4) {
    const a = pixels[i + 3] / maximum
    const r = decode(pixels[i] / maximum) * a,
      g = decode(pixels[i + 1] / maximum) * a,
      b = decode(pixels[i + 2] / maximum) * a
    for (let c = 0; c < 3; c++)
      output[i + c] =
        matrix[c * 3] * r + matrix[c * 3 + 1] * g + matrix[c * 3 + 2] * b
    output[i + 3] = a
  }
  return output
}
