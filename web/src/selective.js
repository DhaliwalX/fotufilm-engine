import { decodeRGBA } from './engine.js'

export const selectionKeys = [
  'ev',
  'temperature',
  'tint',
  'highlights',
  'shadows',
  'saturation',
  'vibrance',
  ...['Shadows', 'Midtones', 'Highlights'].flatMap((band) =>
    ['Warmth', 'Tint', 'Level'].map((axis) => `grade${band}${axis}`),
  ),
]

export function selectionDevelop(edit) {
  return {
    params: Object.fromEntries(
      selectionKeys.map((key) => [key, edit.params[key]]),
    ),
    localTone: edit.localTone,
    gradeSpace: edit.gradeSpace,
  }
}

export function newSelection(edit) {
  return {
    kind: 'color',
    point: null,
    sample: null,
    range: 0.25,
    softness: 0.5,
    ...selectionDevelop(edit),
  }
}

export function sampleScene(source, point) {
  const x = Math.min(
    source.width - 1,
    Math.max(0, Math.floor(point[0] * source.width)),
  )
  const y = Math.min(
    source.height - 1,
    Math.max(0, Math.floor(point[1] * source.height)),
  )
  const left = Math.max(0, x - 2),
    top = Math.max(0, y - 2)
  const width = Math.min(source.width, x + 3) - left
  const height = Math.min(source.height, y + 3) - top
  const pixels = decodeRGBA(source.read(left, top, width, height))
  const sample = [0, 0, 0]
  let weight = 0
  for (let i = 0; i < pixels.length; i += 4) {
    weight += pixels[i + 3]
    for (let c = 0; c < 3; c++) sample[c] += pixels[i + c] * pixels[i + 3]
  }
  return sample.map((v) => (weight > 0 ? v / weight : 0))
}

const luma = (c) => 0.2627002 * c[0] + 0.6779981 * c[1] + 0.0593017 * c[2]
const chroma = (c) => {
  const y = Math.max(luma(c), 1e-4)
  return [(c[0] - y) / (y + 0.25), (c[2] - y) / (y + 0.25)]
}

// SelectiveMask.swift: select the undeveloped scene by Rec.2020 opponent
// chroma or luminance. The saved sample remains stable when the film changes.
export function selectionWeight(rgb, selection) {
  if (!selection.sample) return 0
  let distance
  if (selection.kind === 'light')
    distance = Math.abs(luma(rgb) - luma(selection.sample))
  else {
    const a = chroma(rgb),
      b = chroma(selection.sample)
    distance = Math.hypot(a[0] - b[0], a[1] - b[1])
  }
  const outer = selection.range,
    inner = outer * (1 - selection.softness)
  const t = Math.max(
    0,
    Math.min(1, (distance - inner) / Math.max(1e-9, outer - inner)),
  )
  return 1 - t * t * (3 - 2 * t)
}

const decode = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
const encode = (c) =>
  c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055

export function compositeSelection(
  source,
  ground,
  developed,
  selection,
  showMask = false,
) {
  const result = ground.slice()
  for (let top = 0; top < source.height; top += 32) {
    const rows = Math.min(32, source.height - top)
    const scene = decodeRGBA(source.read(0, top, source.width, rows))
    for (let i = 0; i < scene.length; i += 4) {
      const weight = selectionWeight(scene.subarray(i, i + 3), selection)
      const offset = top * source.width * 4 + i
      for (let c = 0; c < 3; c++) {
        const base = decode(ground[offset + c] / 255)
        const local = showMask ? 1 : decode(developed[offset + c] / 255)
        result[offset + c] = Math.round(
          255 *
            encode(
              (showMask ? base * 0.3 : base) * (1 - weight) + local * weight,
            ),
        )
      }
    }
  }
  return result
}
