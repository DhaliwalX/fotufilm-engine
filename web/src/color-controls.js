import { CONFIG, OBSERVER } from './engine-constants.js'

export const clamp = (value, low, high) => Math.min(high, Math.max(low, value))
const multiply = (m, v) => [0, 3, 6].map((i) => m[i] * v[0] + m[i + 1] * v[1] + m[i + 2] * v[2])
const uvFromXY = ([x, y]) => [(4 * x) / (-2 * x + 12 * y + 3), (6 * y) / (-2 * x + 12 * y + 3)]
const xyFromUV = ([u, v]) => [(3 * u) / (2 * u - 8 * v + 4), (2 * v) / (2 * u - 8 * v + 4)]

// WhiteBalance.swift: CIE daylight above 5000 K, integrated Planckian below 4000 K.
function locus(temperature) {
  const t = clamp(temperature, 1000, 25000)
  const td = clamp(t, 4000, 25000)
  const x =
    td <= 7000
      ? 0.244063 + 99.11 / td + 2967800 / td ** 2 - 4607000000 / td ** 3
      : 0.23704 + 247.48 / td + 1901800 / td ** 2 - 2006400000 / td ** 3
  const daylight = [x, -3 * x * x + 2.87 * x - 0.275]
  if (t >= 5000) return daylight
  const xyz = [OBSERVER.xBar, OBSERVER.yBar, OBSERVER.zBar].map((observer) =>
    observer.reduce((sum, value, i) => {
      const wavelength = 380 + 5 * i
      return sum + value / (wavelength ** 5 * Math.expm1(14387769 / (wavelength * t)))
    }, 0),
  )
  const total = xyz.reduce((a, b) => a + b, 0)
  const planckian = [xyz[0] / total, xyz[1] / total]
  if (t <= 4000) return planckian
  const s = (t - 4000) / 1000
  const blend = s * s * (3 - 2 * s)
  const p = uvFromXY(planckian),
    d = uvFromXY(daylight)
  return xyFromUV(p.map((value, i) => value + (d[i] - value) * blend))
}
function chromaticity(t, tint) {
  const base = locus(t)
  if (!tint) return base
  const ahead = uvFromXY(locus(t + 10)),
    behind = uvFromXY(locus(t - 10))
  const tangent = ahead.map((v, i) => v - behind[i])
  const length = Math.hypot(...tangent)
  if (length <= 1e-9) return base
  const normal = [-tangent[1] / length, tangent[0] / length]
  const sign = normal[1] >= 0 ? 1 : -1
  return xyFromUV(uvFromXY(base).map((v, i) => v + (sign * normal[i] * tint) / 10000))
}
function workingRGB([x, y]) {
  const p3 = multiply(
    [
      2.4934969, -0.9313836, -0.4027108, -0.829489, 1.7626641, 0.0236247, 0.0358458, -0.0761724,
      0.9568845,
    ],
    [x / y, 1, (1 - x - y) / y],
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
  const gains = destination.map((v, i) => v / Math.max(source[i], 1e-6))
  return [gains[0] / gains[1], 1, gains[2] / gains[1]]
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
