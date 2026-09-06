export const SLIDERS = [
  { key: 'ev', label: 'Exposure', min: -3, max: 3, step: 0.05, def: 0, unit: 'EV', group: 'Light' },
  { key: 'highlights', label: 'Highlights', min: -1, max: 1, step: 0.01, def: 0, group: 'Light' },
  { key: 'shadows', label: 'Shadows', min: -1, max: 1, step: 0.01, def: 0, group: 'Light' },
  {
    key: 'temperature',
    label: 'Temperature',
    min: 2000,
    max: 12000,
    step: 1,
    def: 6504,
    unit: 'K',
    group: 'White Balance',
  },
  { key: 'tint', label: 'Tint', min: -100, max: 100, step: 1, def: 0, group: 'White Balance' },
  {
    key: 'saturation',
    label: 'Saturation',
    min: 0,
    max: 2,
    step: 0.01,
    def: 1,
    unit: '×',
    group: 'Color',
  },
  { key: 'vibrance', label: 'Vibrance', min: -1, max: 1, step: 0.01, def: 0, group: 'Color' },
  {
    key: 'grain',
    label: 'Grain',
    min: 0,
    max: 2,
    step: 0.01,
    def: 1,
    unit: '×',
    group: 'Character',
  },
  ...['Shadows', 'Midtones', 'Highlights'].flatMap((band) =>
    ['Warmth', 'Tint', 'Level'].map((axis) => ({
      key: `grade${band}${axis}`,
      label: axis,
      min: -1,
      max: 1,
      step: 0.01,
      def: 0,
      group: band,
    })),
  ),
]
export const fullCrop = () => [
  [0, 0],
  [1, 0],
  [1, 1],
  [0, 1],
]
export const defaultEdit = (stock = null) => ({
  stock,
  params: Object.fromEntries(SLIDERS.map((s) => [s.key, s.def])),
  gradeSpace: false,
  localTone: true,
  seed: 0,
  rotation: 0,
  flip: false,
  straighten: 0,
  crop: fullCrop(),
  ratio: 'free',
})
export const initialHistory = { past: [], present: defaultEdit(), future: [], group: null }
export function historyReducer(state, action) {
  if (action.type === 'restore') return action.history
  if (action.type === 'load') return { past: [], present: action.edit, future: [], group: null }
  if (action.type === 'end') return { ...state, group: null }
  if (action.type === 'undo') {
    if (!state.past.length) return state
    return {
      past: state.past.slice(0, -1),
      present: state.past.at(-1),
      future: [state.present, ...state.future],
      group: null,
    }
  }
  if (action.type === 'redo') {
    if (!state.future.length) return state
    return {
      past: [...state.past, state.present],
      present: state.future[0],
      future: state.future.slice(1),
      group: null,
    }
  }
  if (action.type === 'edit') {
    const next = { ...state.present, ...action.patch }
    if (JSON.stringify(next) === JSON.stringify(state.present)) return state
    const grouped = action.group && state.group === action.group
    return {
      past: grouped ? state.past : [...state.past.slice(-99), state.present],
      present: next,
      future: [],
      group: action.group || null,
    }
  }
  return state
}
export function validCrop(points) {
  return (
    Array.isArray(points) &&
    points.length === 4 &&
    points.every(
      (p) =>
        Array.isArray(p) &&
        p.length === 2 &&
        p.every((v) => Number.isFinite(v) && v >= 0 && v <= 1),
    ) &&
    points.every((a, i) => {
      const b = points[(i + 1) % 4],
        c = points[(i + 2) % 4]
      return (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) > 0.0001
    })
  )
}
export function rotatedCrop(crop, mirrored = false) {
  return mirrored
    ? [crop[3], crop[0], crop[1], crop[2]].map(([x, y]) => [1 - y, x])
    : [crop[1], crop[2], crop[3], crop[0]].map(([x, y]) => [y, 1 - x])
}
export const flippedCrop = (crop) =>
  [crop[1], crop[0], crop[3], crop[2]].map(([x, y]) => [1 - x, y])
export function cropForRatio(ratio, width, height) {
  if (ratio === 'free' || ratio === 'original') return fullCrop()
  const [a, b] = ratio.split(':').map(Number)
  const target = a / b,
    aspect = width / height
  const w = Math.min(1, target / aspect),
    h = Math.min(1, aspect / target)
  return [
    [(1 - w) / 2, (1 - h) / 2],
    [(1 + w) / 2, (1 - h) / 2],
    [(1 + w) / 2, (1 + h) / 2],
    [(1 - w) / 2, (1 + h) / 2],
  ]
}
export function parseEdit(json, stockIDs) {
  const saved = JSON.parse(json)
  if (saved.version !== 1 || !saved.edit) throw new Error('Unsupported edit file.')
  const edit = saved.edit,
    base = defaultEdit(edit.stock)
  if (edit.stock !== null && !stockIDs.includes(edit.stock))
    throw new Error('The film in this edit is not installed.')
  if (
    !edit.params ||
    !SLIDERS.every(
      (s) =>
        Number.isFinite(edit.params[s.key]) &&
        edit.params[s.key] >= s.min &&
        edit.params[s.key] <= s.max,
    )
  )
    throw new Error('Invalid adjustment values.')
  if (
    !validCrop(edit.crop) ||
    ![0, 1, 2, 3].includes(edit.rotation) ||
    typeof edit.flip !== 'boolean' ||
    typeof edit.gradeSpace !== 'boolean' ||
    typeof edit.localTone !== 'boolean' ||
    !Number.isFinite(edit.straighten) ||
    Math.abs(edit.straighten) > 15 ||
    !Number.isInteger(edit.seed) ||
    edit.seed < 0 ||
    edit.seed > 0xffffffff ||
    !['free', 'original', '1:1', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16'].includes(edit.ratio)
  )
    throw new Error('Invalid frame settings.')
  return {
    ...base,
    ...Object.fromEntries(Object.keys(base).map((key) => [key, edit[key]])),
    params: Object.fromEntries(SLIDERS.map((s) => [s.key, edit.params[s.key]])),
  }
}
