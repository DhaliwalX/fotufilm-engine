import { EDITOR_CONTROLS } from './generated/controls.js'

export const editorControl = (field) => {
  const control = EDITOR_CONTROLS.find((entry) => entry.field === field)
  if (!control) throw new Error(`Unknown editor control: ${field}`)
  return control
}

// The native catalogue owns labels, ranges, defaults and help. Browser-specific
// interaction increments do not change the values admitted by that catalogue.
export function catalogueSlider(field, group, step = 0.01) {
  const control = editorControl(field),
    scale = control.scale
  if (!scale) throw new Error(`No numeric scale for ${field}`)
  return {
    key: field,
    label: control.title,
    detail: control.detail,
    availability: control.availability,
    group,
    step,
    min: scale.min,
    max: scale.max,
    def: scale.neutral,
    unit:
      { stops: 'EV', stopsFromOff: 'EV', years: 'yr', kelvin: 'K', multiplier: '×', degrees: '°' }[scale.unit] ||
      '',
  }
}

export function sourceIlluminant(edit) {
  const choice = editorControl('sceneLight').choices.find(
    (c) => c.id === edit.sceneLight,
  )
  if (!choice) throw new Error('Invalid source illuminant.')
  return choice.id === 'custom'
    ? edit.params.sceneLightKelvin
    : choice.value || null
}

export const inspectorPanels = [
  { id: 'film', icon: 'film', title: 'Film' },
  { id: 'light', icon: 'expose', title: 'Expose' },
  { id: 'develop', icon: 'develop', title: 'Develop' },
  { id: 'print', icon: 'print', title: 'Print' },
]
