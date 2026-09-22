export function differences(reference, actual) {
  if (reference.length !== actual.length) throw new Error('Output sizes differ')
  let maximum = 0,
    squared = 0,
    changed = 0,
    nonfinite = 0
  for (let i = 0; i < reference.length; i++) {
    const delta = Math.abs(reference[i] - actual[i])
    if (!Number.isFinite(delta)) {
      nonfinite++
      continue
    }
    maximum = Math.max(maximum, delta)
    squared += delta * delta
    changed += delta !== 0
  }
  return {
    maximum,
    rmse: Math.sqrt(squared / reference.length),
    changed,
    samples: reference.length,
    nonfinite,
  }
}

export function acceptsImage({ linear, byte, deep }) {
  return (
    !linear.nonfinite &&
    linear.maximum <= 0.0001 &&
    linear.rmse <= 0.00001 &&
    byte.maximum <= 1 &&
    byte.changed / byte.samples <= 0.001 &&
    deep.maximum <= 4
  )
}
