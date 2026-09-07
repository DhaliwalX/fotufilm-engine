import { integrateSceneLight } from './scene-light-math.js'

let assets
async function loadAssets(base) {
  const response = await fetch(new URL('index.json', base))
  if (!response.ok) throw new Error('Scene-light data could not be loaded. Rebuild browser packs.')
  const catalog = await response.json()
  const row = (v) => Array.isArray(v) && v.length === 81 && v.every(Number.isFinite)
  if (
    catalog.version !== 1 ||
    catalog.bands !== 81 ||
    catalog.dimension !== 33 ||
    catalog.stride !== 85 ||
    !row(catalog.wavelengths) ||
    !row(catalog.yBar) ||
    !Array.isArray(catalog.daylight) ||
    catalog.daylight.length !== 3 ||
    !catalog.daylight.every(row) ||
    !Array.isArray(catalog.stocks) ||
    !catalog.stocks.length ||
    !catalog.stocks.every(
      (s) =>
        typeof s.id === 'string' &&
        Array.isArray(s.sensitivity) &&
        [3, 4].includes(s.sensitivity.length) &&
        s.sensitivity.every(row) &&
        Array.isArray(s.denominators) &&
        s.denominators.length === s.sensitivity.length &&
        s.denominators.every((v) => Number.isFinite(v) && v > 0),
    )
  )
    throw new Error('Invalid scene-light catalog. Rebuild browser packs.')
  const compressed = await fetch(new URL('geometry.spectra', base))
  if (!compressed.ok) throw new Error('Scene spectra could not be loaded. Rebuild browser packs.')
  const bytes = await new Response(
    compressed.body.pipeThrough(new DecompressionStream('gzip')),
  ).arrayBuffer()
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (v) =>
    v.toString(16).padStart(2, '0'),
  ).join('')
  if (hash !== catalog.geometrySHA256 || bytes.byteLength !== 33 ** 3 * 85 * 4)
    throw new Error('Scene spectral assets do not match. Rebuild browser packs.')
  const geometry = new Float32Array(bytes)
  if (!geometry.every(Number.isFinite)) throw new Error('Invalid scene spectral samples.')
  return { catalog, geometry }
}
self.onmessage = async ({ data: { id, stock, kelvin, base } }) => {
  try {
    self.postMessage({ id, status: 'Loading scene spectra' })
    assets ??= loadAssets(base).catch((error) => {
      assets = null
      throw error
    })
    const { catalog, geometry } = await assets
    self.postMessage({
      id,
      status: `Integrating film sensitivity · ${Math.round(kelvin)} K capture light`,
    })
    const exposure = integrateSceneLight(catalog, geometry, stock, kelvin)
    self.postMessage({ id, exposure }, [exposure.buffer])
  } catch (error) {
    self.postMessage({ id, error: error.message })
  }
}
