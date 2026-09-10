// Illuminant.atLocus on the native wavelength grid. Float rounding follows Swift
// where it matters; no RGB saturation adjustment substitutes for the spectral solve.
export function sceneSpectrum(kelvin, catalog) {
  const f = Math.fround,
    t = f(Math.max(1000, Math.min(25000, kelvin)))
  const planck = () => {
    const values = catalog.wavelengths.map((w) =>
      f(1 / f(f(w ** 5) * f(f(Math.exp(f(14387769 / f(w * t)))) - 1))),
    )
    const peak = Math.max(...values)
    const normalized = values.map((v) => f(v / peak))
    return normalized.map((v) => f(v / normalized[36]))
  }
  const daylight = () => {
    const k = Math.max(4000, t)
    const x =
      k <= 7000
        ? 0.244063 + 0.09911e3 / k + 2.9678e6 / (k * k) - 4.607e9 / (k * k * k)
        : 0.23704 + 0.24748e3 / k + 1.9018e6 / (k * k) - 2.0064e9 / (k * k * k)
    const y = f(-3 * x * x + 2.87 * x - 0.275),
      xf = f(x)
    const m = 0.0241 + 0.2562 * xf - 0.7341 * y
    const m1 = f((-1.3515 - 1.7703 * xf + 5.9114 * y) / m)
    const m2 = f((0.03 - 31.4424 * xf + 30.0717 * y) / m)
    const [s0, s1, s2] = catalog.daylight
    return s0.map((v, i) => f(f(f(f(v) + f(m1 * f(s1[i]))) + f(m2 * f(s2[i]))) / 100))
  }
  if (t <= 4000) return planck()
  if (t >= 5000) return daylight()
  const a = planck(),
    b = daylight(),
    s = f((t - 4000) / 1000),
    weight = f(f(s * s) * f(3 - f(2 * s)))
  return a.map((v, i) => f(f(f(1 - weight) * v) + f(weight * b[i])))
}

export function integrateSceneLight(catalog, geometry, stockID, kelvin) {
  if (!Number.isFinite(kelvin) || kelvin <= 0) throw new Error('Invalid capture temperature.')
  const stock = catalog.stocks.find((s) => s.id === stockID)
  if (!stock)
    throw new Error('Scene-light data is unavailable for this film. Rebuild browser packs.')
  const spectrum = sceneSpectrum(kelvin, catalog), bands = catalog.bands
  // Native spectralExposure normalizes both scene and film-reference SPDs to
  // equal photometric Y. The catalog denominators use that same normalization.
  const sceneY = Math.fround(spectrum.reduce((sum, v, i) => sum + v * catalog.yBar[i], 0))
  const light = spectrum.map((v) => Math.fround(v / sceneY))
  const white = light.reduce((sum, v, i) => Math.fround(sum + Math.fround(v * catalog.yBar[i])), 0)
  const layers = stock.sensitivity.length,
    count = catalog.dimension ** 3
  const weighted = stock.sensitivity.map((row) => row.map((v, i) => v * light[i]))
  const result = new Float32Array(count * 4)
  for (let p = 0; p < count; p++) {
    const base = p * catalog.stride,
      extra = base + bands
    for (let c = 0; c < layers; c++) {
      let reflected = 0
      for (let b = 0; b < bands; b++) reflected += geometry[base + b] * weighted[c][b]
      const mono =
        white *
        (geometry[extra + 2] * stock.sensitivity[c][geometry[extra]] +
          geometry[extra + 3] * stock.sensitivity[c][geometry[extra + 1]])
      result[p * 4 + c] = (Math.max(reflected, 0) + mono) / Math.max(stock.denominators[c], 1e-12)
    }
    if (layers === 3) result[p * 4 + 3] = 1
  }
  return result
}
