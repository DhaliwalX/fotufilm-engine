import { CONFIG, OBSERVER, ILLUMINANT } from './engine-constants.js'
import { sceneSpectrum } from './scene-light-math.js'

export const clamp = (value, low, high) => Math.min(high, Math.max(low, value))
const f = Math.fround
const multiply = (m, v) => [0, 3, 6].map((i) =>
  f(f(f(f(m[i]) * v[0]) + f(f(m[i + 1]) * v[1])) + f(f(m[i + 2]) * v[2])),
)
const uvFromXY = ([x, y]) => {
  const d = f(f(f(-2 * x) + f(12 * y)) + 3)
  return Math.abs(d) > 1e-9 ? [f(f(4 * x) / d), f(f(6 * y) / d)] : [0, 0]
}
const xyFromUV = ([u, v]) => {
  const d = f(f(f(2 * u) - f(8 * v)) + 4)
  return Math.abs(d) > 1e-9 ? [f(f(3 * u) / d), f(f(2 * v) / d)] : [f(0.3127), f(0.329)]
}

// WhiteBalance.swift integrates the same illuminant spectrum used for film exposure.
function locus(temperature) {
  const spectrum = sceneSpectrum(temperature, ILLUMINANT)
  const xyz = [OBSERVER.xBar, OBSERVER.yBar, OBSERVER.zBar].map((observer) =>
    observer.reduce((sum, value, i) => f(sum + f(f(value) * spectrum[i])), 0),
  )
  const total = f(f(xyz[0] + xyz[1]) + xyz[2])
  return [f(xyz[0] / total), f(xyz[1] / total)]
}
const boundary = OBSERVER.xBar.map((x, i) => {
  const y = f(OBSERVER.yBar[i]), z = f(OBSERVER.zBar[i]), total = f(f(f(x) + y) + z)
  return uvFromXY([f(f(x) / total), f(y / total)])
})
function chromaticity(temperature, tint) {
  const t = clamp(f(temperature), 1000, 25000)
  const base = locus(t)
  if (!tint) return base
  const ahead = uvFromXY(locus(t + 10)),
    behind = uvFromXY(locus(t - 10))
  const tangent = ahead.map((v, i) => f(v - behind[i]))
  const length = f(Math.sqrt(f(f(tangent[0] ** 2) + f(tangent[1] ** 2))))
  if (length <= 1e-9) return base
  const normal = [f(-tangent[1] / length), f(tangent[0] / length)]
  const sign = normal[1] >= 0 ? 1 : -1
  const uv = uvFromXY(base), displacement = normal.map((v) => f(sign * v * f(f(tint) / 10000)))
  const cross = (a, b) => f(f(a[0] * b[1]) - f(a[1] * b[0]))
  let fraction = 1
  for (let i = 0; i < boundary.length; i++) {
    const a = boundary[i].map((v, j) => f(v - uv[j]))
    const edge = boundary[(i + 1) % boundary.length].map((v, j) => f(v - boundary[i][j]))
    const denominator = cross(displacement, edge)
    if (Math.abs(denominator) <= 1e-12) continue
    const distance = f(cross(a, edge) / denominator), along = f(cross(a, displacement) / denominator)
    if (distance >= 0 && distance < 1 && along >= 0 && along <= 1)
      fraction = Math.min(fraction, f(distance * f(0.95)))
  }
  return xyFromUV(uv.map((v, i) => f(v + f(displacement[i] * fraction))))
}
function workingRGB([x, y]) {
  if (y <= 1e-6) return [1, 1, 1]
  const p3 = multiply(
    [
      2.4934969, -0.9313836, -0.4027108, -0.829489, 1.7626641, 0.0236247, 0.0358458, -0.0761724,
      0.9568845,
    ],
    [f(x / y), 1, f(f(f(1 - x) - y) / y)],
  )
  return multiply(
    [
      0.753833034, 0.198597369, 0.047569597, 0.045743849, 0.94177722, 0.012478931, -0.00121034,
      0.017601717, 0.983608623,
    ],
    p3,
  )
}
export function whiteBalanceGains(temperature = 6504, tint = 0) {
  if (temperature === 6504 && tint === 0) return [1, 1, 1]
  const source = workingRGB(chromaticity(temperature, tint))
  const destination = workingRGB(chromaticity(6504, 0))
  const gains = destination.map((v, i) => f(v / Math.max(source[i], f(1e-6))))
  return [f(gains[0] / gains[1]), 1, f(gains[2] / gains[1])]
}

// ColorGrade.swift: lift, gain, and inverse gamma in the engine's own working space.
export function packedGrade(controls) {
  const tilt = (band) => {
    const x = controls[`${band}Warmth`] || 0,
      y = controls[`${band}Tint`] || 0
    return [x - 0.5 * y, y, -x - 0.5 * y]
  }
  return [
    ...tilt('gradeShadows').map((v) => 0.04 * (controls.gradeShadowsLevel || 0) + 0.02 * v),
    ...tilt('gradeHighlights').map(
      (v) => 2 ** (0.6 * (controls.gradeHighlightsLevel || 0) + 0.3 * v),
    ),
    ...tilt('gradeMidtones').map((v) => 2 ** -(0.5 * (controls.gradeMidtonesLevel || 0) + 0.3 * v)),
  ]
}

export function applyColorControls(configuration, controls) {
  configuration.set(whiteBalanceGains(controls.temperature, controls.tint), CONFIG.WHITE_BALANCE)
  configuration.set(packedGrade(controls), CONFIG.GRADE_LIFT)
  configuration[CONFIG.GRADE_SPACE] = controls.gradeSpace ? 1 : 0
}
