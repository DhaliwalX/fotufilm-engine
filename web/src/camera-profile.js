// Anchors and the white-balance locus are exported by the native engine. The
// browser performs only the same small matrix interpolation as the Mac app.
export function cameraKey(make, model) {
  if (typeof make !== 'string' || typeof model !== 'string') return null
  const brand = make.trim().toLowerCase().split(/\s+/)[0]
  const parts = model.trim().toLowerCase().split(/\s+/)
  if (parts.length > 1 && parts[0] === brand) parts.shift()
  return brand && parts[0] ? `${brand}\x1f${parts.join(' ')}` : null
}

export function inverse3(matrix) {
  if (!Array.isArray(matrix) || matrix.length !== 9 || !matrix.every(Number.isFinite)) return null
  const rows = Array.from({ length: 3 }, (_, r) => [
    ...matrix.slice(r * 3, r * 3 + 3),
    ...[0, 1, 2].map((c) => +(r === c)),
  ])
  for (let c = 0; c < 3; c++) {
    let pivot = c
    for (let r = c + 1; r < 3; r++) if (Math.abs(rows[r][c]) > Math.abs(rows[pivot][c])) pivot = r
    if (Math.abs(rows[pivot][c]) <= 1e-12) return null
    ;[rows[c], rows[pivot]] = [rows[pivot], rows[c]]
    const lead = rows[c][c]
    rows[c] = rows[c].map((v) => v / lead)
    for (let r = 0; r < 3; r++) {
      if (r === c) continue
      const factor = rows[r][c]
      rows[r] = rows[r].map((v, k) => v - factor * rows[c][k])
    }
  }
  return rows.flatMap((row) => row.slice(3))
}

export function profileCorrection(profile, kelvin, catalog) {
  if (!Number.isFinite(kelvin) || kelvin <= 0) return null
  const inverse = inverse3(profile.daylight)
  if (!inverse) return null
  // Float rounding follows DualIlluminantMatrices.matrix; its inverse/product
  // intentionally use double precision before the final Float conversion.
  const f = Math.fround
  const cool = f(1 / catalog.daylightKelvin),
    warm = f(1 / catalog.tungstenKelvin)
  const weight = Math.max(
    0,
    Math.min(1, f(f(f(1 / Math.max(f(kelvin), 1)) - cool) / f(warm - cool))),
  )
  const matrix = []
  for (let r = 0; r < 3; r++) {
    let row = profile.daylight.slice(r * 3, r * 3 + 3)
    if (weight === 1) row = profile.tungsten.slice(r * 3, r * 3 + 3)
    else if (weight !== 0) {
      row = row.map((v, c) => f(f(weight * profile.tungsten[r * 3 + c]) + f(f(1 - weight) * v)))
      const sum = f(f(row[0] + row[1]) + row[2])
      if (Math.abs(sum) > 1e-4) row = row.map((v) => f(v / sum))
    }
    let out = [0, 1, 2].map((c) => row.reduce((sum, v, k) => sum + v * inverse[k * 3 + c], 0))
    const sum = out.reduce((a, b) => a + b, 0)
    if (Math.abs(sum) > 1e-4) out = out.map((v) => v / sum)
    matrix.push(...out.map(f))
  }
  return matrix
}

// Camera neutral = reciprocal as-shot gains. Transform it to XYZ using
// the decoder's active camera matrix, then project onto the native CIE 1960 uv
// locus. This estimates CCT independently of green/magenta tint; it does not
// assume that another decoder reports the same temperature for that white.
export function estimateAsShotKelvin(metadata, locus) {
  if (
    metadata.channels !== 3 ||
    !metadata.whiteBalance?.every((v) => Number.isFinite(v) && v > 0) ||
    metadata.whiteBalance.length !== 3
  )
    return null
  if (!inverse3(metadata.cameraToXYZ)) return null
  const xyz = [0, 1, 2].map((r) =>
    metadata.whiteBalance.reduce((s, v, c) => s + metadata.cameraToXYZ[r * 3 + c] / v, 0),
  )
  if (!xyz.every((v) => Number.isFinite(v) && v > 0)) return null
  const denominator = xyz[0] + 15 * xyz[1] + 3 * xyz[2]
  const u = (4 * xyz[0]) / denominator,
    v = (6 * xyz[1]) / denominator
  let best = Infinity,
    kelvin = null
  for (let i = 1; i < locus.length; i++) {
    const [ka, ua, va] = locus[i - 1],
      [kb, ub, vb] = locus[i]
    const du = ub - ua,
      dv = vb - va,
      length = du * du + dv * dv
    if (length <= 0) continue
    const t = Math.max(0, Math.min(1, ((u - ua) * du + (v - va) * dv) / length))
    const distance = (u - ua - t * du) ** 2 + (v - va - t * dv) ** 2
    if (distance < best) {
      best = distance
      kelvin = 1 / ((1 - t) / ka + t / kb)
    }
  }
  // Do not invent a temperature from corrupt metadata or a white far off-locus.
  return best <= 0.05 ** 2 ? kelvin : null
}

export function resolveCameraProfile(metadata, catalog) {
  const key = cameraKey(metadata.make, metadata.model)
  const profile = key && catalog.profiles.find((p) => cameraKey(p.make, p.model) === key)
  if (!profile) return null
  const kelvin = estimateAsShotKelvin(metadata, catalog.whiteLocus)
  const matrix = profileCorrection(profile, kelvin, catalog)
  return matrix
    ? { id: profile.id, name: `${profile.make} ${profile.model}`, kelvin, matrix }
    : null
}

export async function loadCameraProfiles(url) {
  const response = await fetch(url)
  if (!response.ok)
    throw new Error('Camera profiles could not be loaded. Rebuild and publish the RAW runtime.')
  const data = await response.json()
  const matrix = (v) => Array.isArray(v) && v.length === 9 && v.every(Number.isFinite)
  if (
    data.version !== 1 ||
    data.tungstenKelvin !== 2856 ||
    data.daylightKelvin !== 6504 ||
    !Array.isArray(data.profiles) ||
    !data.profiles.length ||
    !data.profiles.every(
      (p) =>
        typeof p.id === 'string' &&
        cameraKey(p.make, p.model) &&
        matrix(p.tungsten) &&
        matrix(p.daylight),
    ) ||
    !Array.isArray(data.whiteLocus) ||
    data.whiteLocus.length < 2 ||
    !data.whiteLocus.every(
      (row) => Array.isArray(row) && row.length === 3 && row.every(Number.isFinite) && row[0] > 0,
    )
  )
    throw new Error('Camera profiles are invalid. Rebuild and publish the RAW runtime.')
  return data
}
