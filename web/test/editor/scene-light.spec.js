import { test, expect } from '@playwright/test'
import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'
import { integrateSceneLight } from '../../src/scene-light-math.js'

const root = fileURLToPath(new URL('../../../', import.meta.url))
test('browser spectral integration agrees with native scene exposure across films and capture lights', () => {
  test.setTimeout(180000)
  const catalog = JSON.parse(readFileSync(join(root, 'web/public/packs/scene/index.json')))
  const bytes = gunzipSync(readFileSync(join(root, 'web/public/packs/scene/geometry.spectra')))
  const geometry = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.length / 4)
  const folder = mkdtempSync(join(tmpdir(), 'fotufilm-scene-test-'))
  let peak = 0
  try {
    for (const stock of ['gold200', 'vision500t', 'hp5plus400', 'c200', 'ektachromee100'])
      for (const kelvin of [1000, 2000, 3200, 4500, 5060, 6504, 12000, 25000]) {
        const path = join(folder, 'native.f32')
        execFileSync(join(root, '.build/release/fotufilm'), [
          '--dump-scene-exposure',
          path,
          '--stock',
          stock,
          '--scene-kelvin',
          String(kelvin),
        ])
        const referenceBytes = readFileSync(path)
        const reference = new Float32Array(
          referenceBytes.buffer,
          referenceBytes.byteOffset,
          referenceBytes.length / 4,
        )
        const actual = integrateSceneLight(catalog, geometry, stock, kelvin)
        assert.equal(actual.length, reference.length)
        for (let i = 0; i < actual.length; i++)
          peak = Math.max(peak, Math.abs(actual[i] - reference[i]) / (1 + Math.abs(reference[i])))
      }
    console.log('Native/browser scene-light maximum relative error:', peak)
    assert.ok(peak < 2e-5, `Scene exposure error ${peak}`)
  } finally {
    rmSync(folder, { recursive: true, force: true })
  }
})

test('capture-light worker shares its cached table across media and agrees with native CPU/WebGPU rendering', async ({
  page,
}) => {
  test.setTimeout(120000)
  const folder = mkdtempSync(join(tmpdir(), 'fotufilm-scene-render-'))
  try {
    const path = join(folder, 'native.pack')
    execFileSync(join(root, '.build/release/fotufilm'), [
      '--dump-wasm-pack',
      path,
      '--stock',
      'gold200',
      '--scene-kelvin',
      '5060',
    ])
    const stagesPath = join(folder, 'native.stages')
    execFileSync(join(root, '.build/release/fotufilm'), [
      '--dump-wasm-stages',
      stagesPath,
      '--stock',
      'gold200',
      '--scene-kelvin',
      '5060',
    ])
    await page.route('**/native-scene.stages', (route) =>
      route.fulfill({ body: readFileSync(stagesPath) }),
    )
    await page.route('**/native-scene.pack', (route) => route.fulfill({ body: readFileSync(path) }))
    await page.goto('/')
    const report = await page.evaluate(async () => {
      const { loadSceneExposure } = await import('/src/scene-light.js')
      const { RenderSession } = await import('/src/render-session.js')
      const { loadPack, loadStages, createDeveloper, createCpuDeveloper, pixelSource } =
        await import('/src/engine.js')
      const { defaultEdit } = await import('/src/editor-state.js')
      const progress = []
      const exposure = await loadSceneExposure('gold200', 5060, (s) => progress.push(s))
      const session = new RenderSession()
      const base = (await session.pack('gold200')).pack
      const paper = (await session.pack('gold200', 'lab-scan')).pack
      const corrected = await session.capturePack(base, 'gold200', 5060, () => {})
      const correctedPaper = await session.capturePack(paper, 'gold200', 5060, () => {})
      const native = await loadPack('/native-scene.pack')
      const stages = await loadStages('/native-scene.stages', native)
      const bypass = await loadSceneExposure('gold200@bypassed', 5060)
      let bypassError = 0
      bypass.forEach((v, i) => {
        bypassError = Math.max(
          bypassError,
          Math.abs(v - stages[0].exposure[i]) / (1 + Math.abs(stages[0].exposure[i])),
        )
      })
      let tableError = 0,
        changed = 0
      exposure.forEach((v, i) => {
        tableError = Math.max(
          tableError,
          Math.abs(v - native.exposure[i]) / (1 + Math.abs(native.exposure[i])),
        )
        changed = Math.max(changed, Math.abs(v - base.exposure[i]))
      })
      const data = new Float32Array(120 * 80 * 4)
      for (let i = 0; i < data.length; i += 4) {
        data[i] = ((i / 4) % 120) / 100
        data[i + 1] = Math.floor(i / 480) / 80
        data[i + 2] = 0.15
        data[i + 3] = 1
      }
      const source = pixelSource({ width: 120, height: 80, data })
      const gpu = await createDeveloper(corrected),
        cpu = await createCpuDeveloper(corrected)
      const controls = { ...defaultEdit().params, grain: 0 }
      let gpuPeak = 0,
        nativePeak = 0
      try {
        const a = await gpu.develop(source, controls),
          b = await cpu.develop(source, controls)
        cpu.usePack(native)
        const reference = await cpu.develop(source, controls)
        a.pixels.forEach((v, i) => {
          gpuPeak = Math.max(gpuPeak, Math.abs(v - b.pixels[i]))
          nativePeak = Math.max(nativePeak, Math.abs(v - reference.pixels[i]))
        })
        if (gpu.backend !== 'webgpu') throw new Error('WebGPU required')
      } finally {
        gpu.dispose()
        cpu.dispose()
      }
      const cached = corrected === (await session.capturePack(base, 'gold200', 5060, () => {}))
      const unchanged = base === (await session.capturePack(base, 'gold200', null, () => {}))
      const shared = correctedPaper.exposure === exposure && corrected.exposure === exposure
      await session.dispose()
      return {
        bypassError,
        tableError,
        changed,
        gpuPeak,
        nativePeak,
        cached,
        unchanged,
        shared,
        progress,
      }
    })
    console.log('Capture-light render parity:', report)
    expect(report.bypassError).toBeLessThan(2e-5)
    expect(report.tableError).toBeLessThan(2e-5)
    expect(report.changed).toBeGreaterThan(0.01)
    expect(report.gpuPeak).toBeLessThanOrEqual(2)
    expect(report.nativePeak).toBeLessThanOrEqual(2)
    expect(report.cached && report.unchanged && report.shared).toBe(true)
    expect(report.progress.some((s) => s.includes('5060 K'))).toBe(true)
  } finally {
    rmSync(folder, { recursive: true, force: true })
  }
})

test('missing scene assets report an error instead of using the wrong capture light', async ({
  page,
}) => {
  await page.route('**/packs/scene/index.json', (route) => route.fulfill({ status: 404, body: '' }))
  await page.goto('/')
  const message = await page.evaluate(async () => {
    const { loadSceneExposure } = await import('/src/scene-light.js')
    try {
      await loadSceneExposure('gold200', 5060)
      return ''
    } catch (error) {
      return error.message
    }
  })
  expect(message).toContain('Scene-light data could not be loaded')
})
