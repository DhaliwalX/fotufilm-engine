export const CONTROLS = [
  { key: 'grain', index: 0, label: 'Grain', unit: '×', min: 0.0, max: 2.0, step: 0.05, def: 1.0, signed: false, kind: 'grain' },
  { key: 'exposure', index: 1, label: 'Exposure', unit: 'ev', min: -2.0, max: 2.0, step: 0.25, def: 0.0, signed: true, kind: 'exp2' },
  { key: 'highlights', index: 2, label: 'Highlights', unit: '', min: -1.0, max: 1.0, step: 0.05, def: 0.0, signed: true, kind: 'identity' },
  { key: 'shadows', index: 3, label: 'Shadows', unit: '', min: -1.0, max: 1.0, step: 0.05, def: 0.0, signed: true, kind: 'identity' },
  { key: 'saturation', index: 4, label: 'Saturation', unit: '×', min: 0.0, max: 2.0, step: 0.05, def: 1.0, signed: false, kind: 'identity' },
  { key: 'vibrance', index: 5, label: 'Vibrance', unit: '', min: -1.0, max: 1.0, step: 0.05, def: 0.0, signed: true, kind: 'identity' },
]
