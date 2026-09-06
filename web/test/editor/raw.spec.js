import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { makeDNG } from './raw-fixture.js'

async function ready(page) {
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/)
}

test('RAW worker decodes sensor pixels at 16 bits without shared memory, honoring orientation', async ({
  page,
}) => {
  await page.goto('/')
  const report = await page.evaluate(
    async (bytes) => {
      const { decodeRaw } = await import('/src/raw-import.js')
      const image = await decodeRaw(new File([new Uint8Array(bytes)], 'test.dng'))
      return {
        width: image.naturalWidth,
        height: image.naturalHeight,
        bits: image.raw.data.BYTES_PER_ELEMENT * 8,
        codes: new Set(image.raw.data).size,
        isolated: crossOriginIsolated,
        colors: image.raw.colors,
      }
    },
    Array.from(makeDNG({ orientation: 6 })),
  )
  expect(report).toMatchObject({
    width: 192,
    height: 320,
    bits: 16,
    colors: 3,
    isolated: false,
  })
  expect(report.codes).toBeGreaterThan(256)
})

test('RAW import, film, exposure, crop and export use the full original', async ({ page }) => {
  const errors = []
  page.on('pageerror', (error) => errors.push(error.message))
  await page.goto('/')
  await page.locator('input[type=file][multiple]').setInputFiles({
    name: 'sensor.dng',
    mimeType: 'image/x-adobe-dng',
    buffer: Buffer.from(makeDNG()),
  })
  await ready(page)
  await expect(page.locator('.pixel-readout')).toContainText('RAW')
  await page.getByRole('searchbox').fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await ready(page)
  await expect(page.locator('.backend-label')).toHaveText('WebGPU')
  await page.getByRole('tab', { name: 'Light & Color' }).click()
  await page.getByRole('spinbutton', { name: 'Exposure value', exact: true }).fill('2')
  await page.getByRole('spinbutton', { name: 'Exposure value', exact: true }).press('Tab')
  await ready(page)
  await page.getByRole('tab', { name: 'Crop', exact: true }).click()
  await ready(page)
  await page.getByRole('combobox', { name: 'Aspect ratio', exact: true }).click()
  await page.getByRole('option', { name: '1:1', exact: true }).click()
  await page.getByRole('button', { name: 'Done', exact: true }).click()
  await ready(page)
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  const promise = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const download = await promise,
    png = await readFile(await download.path())
  expect(png.readUInt32BE(16)).toBe(192)
  expect(png.readUInt32BE(20)).toBe(192)
  expect(download.suggestedFilename()).toBe('sensor-gold200.png')
  expect(errors).toEqual([])
})

test('corrupt RAW reports an error, and a following valid import still works', async ({ page }) => {
  await page.goto('/')
  await page.locator('input[type=file][multiple]').setInputFiles({
    name: 'broken.NEF',
    mimeType: '',
    buffer: Buffer.from('not a raw file'),
  })
  await expect(page.getByRole('alert')).toContainText('Could not decode RAW')
  await expect(page.locator('.import-status')).toBeHidden()
  await page.locator('input[type=file][multiple]').setInputFiles({
    name: 'valid.DNG',
    mimeType: '',
    buffer: Buffer.from(makeDNG({ mosaic: false })),
  })
  await ready(page)
  await expect(page.getByRole('alert')).toBeHidden()
})

test('RAW cancellation releases the worker without changing the open photo', async ({ page }) => {
  await page.goto('/')
  await page.route('**/raw/decoder.mjs', () => {})
  await page.locator('input[type=file][multiple]').setInputFiles({
    name: 'slow.dng',
    mimeType: '',
    buffer: Buffer.from(makeDNG()),
  })
  await expect(page.locator('.import-status')).toBeVisible()
  await page.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(page.locator('.import-status')).toBeHidden()
  await page.getByRole('button', { name: 'Open sample chart' }).click()
  await ready(page)
  await expect(page.locator('.document-name')).toContainText('Color chart.png')
})

test('optional camera RAW smoke test', async ({ page }) => {
  test.skip(!process.env.FOTUFILM_TEST_RAW, 'Set FOTUFILM_TEST_RAW to a local camera file.')
  await page.goto('/')
  await page.locator('input[type=file][multiple]').setInputFiles(process.env.FOTUFILM_TEST_RAW)
  await ready(page)
  await expect(page.locator('.pixel-readout')).toContainText('RAW')
  await expect(page.getByRole('alert')).toBeHidden()
  await page.getByRole('searchbox').fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await ready(page)
  await expect(page.locator('.backend-label')).toHaveText('WebGPU')
  const metadata = await page.locator('.viewer-status').innerText()
  console.log('Camera RAW import:', metadata)
})

test('RAW linear pixels agree between CPU and WebGPU after exposure and regional adjustments', async ({
  page,
}) => {
  await page.goto('/')
  const report = await page.evaluate(async (bytes) => {
    const { decodeRaw } = await import('/src/raw-import.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const { loadPack, createDeveloper, SimdDeveloper } = await import('/src/engine.js')
    const image = await decodeRaw(new File([new Uint8Array(bytes)], 'linear.dng'))
    const source = rawSource(image, defaultEdit())
    const pack = await loadPack('/packs/gold200.pack')
    const gpu = await createDeveloper(pack)
    const { default: create } = await import('/fotufilm.mjs')
    const cpu = new SimdDeveloper(await create(), pack)
    const controls = {
      ...defaultEdit().params,
      ev: 1.5,
      shadows: 0.4,
      highlights: -0.3,
      grain: 0,
      temperature: 5500,
      localTone: true,
    }
    try {
      const a = await gpu.develop(source, controls),
        b = await cpu.develop(source, controls)
      let peak = 0,
        sum = 0
      a.pixels.forEach((v, i) => {
        const difference = Math.abs(v - b.pixels[i])
        peak = Math.max(peak, difference)
        sum += difference
      })
      return { backend: gpu.backend, peak, mean: sum / a.pixels.length }
    } finally {
      gpu.dispose()
      cpu.dispose()
    }
  }, Array.from(makeDNG()))
  console.log('RAW CPU/WebGPU comparison:', report)
  expect(report.backend).toBe('webgpu')
  expect(report.peak).toBeLessThanOrEqual(3)
  expect(report.mean).toBeLessThan(0.25)
})
