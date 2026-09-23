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
