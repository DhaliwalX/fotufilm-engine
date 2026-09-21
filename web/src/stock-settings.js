import { hasProfileSettings } from './profile-settings.js'

// A compiled profile can be rendered and graded without distributing its
// authoring definition. Only definition-backed films can rebuild their physics.
export const fixedStockSettings = (stock) => stock?.profile?.settings === 'fixed'

export function selectStockSettings(stock) {
  return fixedStockSettings(stock)
    ? { format: null, profile: {}, filters: [], printFrame: 'none' }
    : {}
}

export function validateStockSettings(edit, stock) {
  if (fixedStockSettings(stock) &&
      (hasProfileSettings(edit) || (edit.printFrame && edit.printFrame !== 'none'))) {
    throw new Error('This film uses a fixed profile. Reset film settings to use exposure, grading, output media and export.')
  }
}
