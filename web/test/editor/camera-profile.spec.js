import { test, expect } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { makeDNG } from './raw-fixture.js'

const cli = fileURLToPath(new URL('../../../.build/release/fotufilm', import.meta.url))
const native = (kelvin) =>
  JSON.parse(
    execFileSync(cli, ['--dump-web-camera-profiles', '-', '--camera-kelvin', String(kelvin)], {
      maxBuffer: 8 * 1024 * 1024,
    }),
  )

test('every bundled camera correction agrees with the native solver at warm, daylight and intermediate temperatures', async ({
  page,
}) => {
  test.setTimeout(120000)
  await page.goto('/')
  for (const kelvin of [2000, 2856, 3200, 4892.5488, 5500, 6504, 12000]) {
    const catalog = native(kelvin)
    const report = await page.evaluate(
      async ({ catalog, kelvin }) => {
        const { profileCorrection, loadCameraProfiles } = await import('/src/camera-profile.js')
        const shipped = await loadCameraProfiles('/raw/camera-profiles.json')
        let peak = 0,
          whiteError = 0
        for (const profile of catalog.profiles) {
          const actual = shipped.profiles.find((p) => p.id === profile.id)
          if (!actual) throw new Error(`Missing profile ${profile.id}`)
          const matrix = profileCorrection(actual, kelvin, shipped)
          matrix.forEach((v, i) => {
            peak = Math.max(peak, Math.abs(v - profile.reference[i]))
          })
          for (let r = 0; r < 3; r++)
            whiteError = Math.max(
              whiteError,
              Math.abs(matrix.slice(r * 3, r * 3 + 3).reduce((a, b) => a + b, 0) - 1),
            )
        }
        return { peak, whiteError, count: shipped.profiles.length }
      },
      { catalog, kelvin },
    )
    expect(report.count).toBeGreaterThan(40)
    expect(report.peak).toBeLessThan(2e-6)
    expect(report.whiteError).toBeLessThan(2e-6)
  }
})

test('known-camera RAW resolves its as-shot spectral correction and applies it once in floating point', async ({
  page,
}) => {
  const catalog = native(3200)
  const [kelvin, u, v] = catalog.whiteLocus.find((row) => Math.abs(row[0] - 3200) < 6)
  const x = (3 * u) / (2 * u - 8 * v + 4),
    y = (2 * v) / (2 * u - 8 * v + 4)
  const xyz = [x / y, 1, (1 - x - y) / y]
  const matrix = [
    3.2404542, -1.5371385, -0.4985314, -0.969266, 1.8760108, 0.041556, 0.0556434, -0.2040259,
    1.0572252,
  ]
  const neutral = [0, 1, 2].map((r) => xyz.reduce((sum, n, c) => sum + n * matrix[r * 3 + c], 0))
  const bytes = Array.from(
    makeDNG({
      make: 'Sony',
      model: 'ILCE-7CM2',
      xyzToCamera: matrix,
      asShotNeutral: neutral.map((n) => n / neutral[1]),
      patches: [
        [0.15, 0.3, 0.1],
        [3, 3, 3],
      ],
    }),
  )
  await page.goto('/')
  const report = await page.evaluate(async (bytes) => {
    const { decodeRaw } = await import('/src/raw-import.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const { loadPack, createDeveloper, createCpuDeveloper } = await import('/src/engine.js')
    const progress = []
    const image = await decodeRaw(new File([new Uint8Array(bytes)], 'profile.dng'), {
      onProgress: (s) => progress.push(s),
    })
    const edit = { ...defaultEdit(), rotation: 1, flip: true }
    const corrected = rawSource(image, edit)
    const plain = rawSource(
      {
        naturalWidth: image.naturalWidth,
        naturalHeight: image.naturalHeight,
        raw: { ...image.raw, profile: null },
      },
      edit,
    )
    const a = corrected.read(0, 0, corrected.width, corrected.height)
    const b = plain.read(0, 0, plain.width, plain.height)
    const m = image.raw.profile.matrix
    let peak = 0,
      changed = 0,
      headroom = 0
    for (let i = 0; i < a.length; i += 4)
      for (let c = 0; c < 3; c++) {
        const expected = m[c * 3] * b[i] + m[c * 3 + 1] * b[i + 1] + m[c * 3 + 2] * b[i + 2]
        peak = Math.max(peak, Math.abs(a[i + c] - expected))
        changed = Math.max(changed, Math.abs(a[i + c] - b[i + c]))
        headroom = Math.max(headroom, a[i + c])
      }
    const pack = await loadPack('/packs/gold200.pack')
    const gpu = await createDeveloper(pack),
      cpu = await createCpuDeveloper(pack)
    let gpuPeak = 0
    try {
      const controls = { ...defaultEdit().params, grain: 0 }
      const gpuResult = await gpu.develop(corrected, controls)
      const cpuResult = await cpu.develop(corrected, controls)
      for (let i = 0; i < gpuResult.pixels.length; i++)
        gpuPeak = Math.max(gpuPeak, Math.abs(gpuResult.pixels[i] - cpuResult.pixels[i]))
      if (gpu.backend !== 'webgpu') throw new Error('WebGPU is required for the parity check')
    } finally {
      gpu.dispose()
      cpu.dispose()
    }
    return { profile: image.raw.profile, peak, changed, headroom, progress, gpuPeak }
  }, bytes)
  expect(report.profile.id.toLowerCase()).toContain('7cm2')
  expect(Math.abs(report.profile.kelvin - kelvin)).toBeLessThan(15)
  expect(report.peak).toBeLessThan(1e-6)
  expect(report.changed).toBeGreaterThan(0.001)
  expect(report.headroom).toBeGreaterThan(1)
  expect(report.gpuPeak).toBeLessThanOrEqual(2)
  expect(report.progress.some((s) => s.includes('spectral correction'))).toBe(true)
})

test('missing camera assets fail explicitly instead of silently omitting correction', async ({
  page,
}) => {
  await page.route('**/raw/camera-profiles.json', (route) =>
    route.fulfill({ status: 404, body: '' }),
  )
  await page.goto('/')
  const error = await page.evaluate(async (bytes) => {
    const { decodeRaw } = await import('/src/raw-import.js')
    try {
      await decodeRaw(new File([new Uint8Array(bytes)], 'test.dng'))
      return ''
    } catch (error) {
      return error.message
    }
  }, Array.from(makeDNG()))
  expect(error).toContain('Camera profiles could not be loaded')
})
