import { test, expect } from '@playwright/test'

test('WebGPU and CPU agree with white balance, regional masks and grading', async ({ page }) => {
  await page.goto('/')
  const report = await page.evaluate(async () => {
    const { loadPack, createDeveloper, SimdDeveloper, pixelSource } = await import('/src/engine.js')
    const pack = await loadPack('/packs/gold200.pack')
    const gpu = await createDeveloper(pack)
    const { default: create } = await import('/fotufilm.mjs')
    const cpu = new SimdDeveloper(await create(), pack)
    const width = 320,
      height = 224,
      data = new Uint8ClampedArray(width * height * 4)
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4
        data[i] = 20 + (x / width) * 190
        data[i + 1] = 20 + (y / height) * 190
        data[i + 2] = x > width / 2 ? 190 : 50
        data[i + 3] = 255
      }
    const source = pixelSource({ data, width, height })
    const controls = {
      ev: 0.3,
      temperature: 4800,
      tint: 12,
      highlights: -0.3,
      shadows: 0.4,
      saturation: 1.1,
      vibrance: 0.1,
      grain: 0,
      localTone: true,
      gradeSpace: true,
      gradeShadowsWarmth: 0.3,
      gradeMidtonesLevel: 0.2,
      gradeHighlightsTint: -0.1,
      seed: 17,
    }
    try {
      const a = await gpu.develop(source, controls),
        b = await cpu.develop(source, controls)
      let total = 0,
        peak = 0,
        changed = 0
      for (let i = 0; i < data.length; i++)
        if (i % 4 !== 3) {
          const delta = Math.abs(a.pixels[i] - b.pixels[i])
          total += delta
          peak = Math.max(peak, delta)
          if (delta) changed++
        }
      const repeat = await gpu.develop(source, controls)
      const deterministic = a.pixels.every((v, i) => v === repeat.pixels[i])
      const grained = await gpu.develop(source, { ...controls, grain: 1 })
      const rerolled = await gpu.develop(source, { ...controls, grain: 1, seed: 18 })
      return {
        backend: gpu.backend,
        mean: total / (width * height * 3),
        peak,
        changed,
        deterministic,
        grainChanges: grained.pixels.some((v, i) => v !== rerolled.pixels[i]),
      }
    } finally {
      gpu.dispose()
      cpu.dispose()
    }
  })
  console.log('WebGPU/CPU comparison:', report)
  expect(report.backend).toBe('webgpu')
  expect(report.mean).toBeLessThan(0.25)
  expect(report.peak).toBeLessThanOrEqual(3)
  expect(report.deterministic).toBe(true)
  expect(report.grainChanges).toBe(true)
})

test('four crop corners move independently; rotate and flip undo cleanly', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Open sample chart' }).click()
  await expect(page.locator('.viewer-status [role=status]')).toContainText('1600 × 1000')
  await page.getByRole('tab', { name: 'Crop', exact: true }).click()
  const corner = page.getByRole('button', { name: 'Top left crop corner', exact: true })
  const original = await page.locator('.crop-overlay polygon').getAttribute('points')
  await corner.focus()
  await corner.press('ArrowRight')
  await corner.press('ArrowDown')
  const edited = await page.locator('.crop-overlay polygon').getAttribute('points')
  expect(edited.split(' ')[0]).not.toBe(original.split(' ')[0])
  expect(edited.split(' ').slice(1)).toEqual(original.split(' ').slice(1))
  await page.getByRole('button', { name: 'Rotate Left', exact: true }).click()
  await page.getByRole('button', { name: 'Undo (⌘Z)', exact: true }).click()
  expect(await page.locator('.crop-overlay polygon').getAttribute('points')).toBe(edited)
  await page.getByRole('button', { name: 'Flip', exact: true }).click()
  await page.getByRole('button', { name: 'Undo (⌘Z)', exact: true }).click()
  expect(await page.locator('.crop-overlay polygon').getAttribute('points')).toBe(edited)
  await page.getByRole('button', { name: 'Reset Crop', exact: true }).click()
  expect(await page.locator('.crop-overlay polygon').getAttribute('points')).toBe(original)
})

test('export retains original dimensions above the preview limit', async ({ page }) => {
  await page.goto('/')
  const source = await page.evaluate(async () => {
    const canvas = document.createElement('canvas')
    canvas.width = 2400
    canvas.height = 1800
    const ctx = canvas.getContext('2d')
    ctx.fillStyle = '#ab7468'
    ctx.fillRect(0, 0, 2400, 1800)
    const blob = await new Promise((resolve) => canvas.toBlob(resolve))
    return Array.from(new Uint8Array(await blob.arrayBuffer()))
  })
  await page
    .locator('input[type=file][multiple]')
    .setInputFiles({ name: 'large.png', mimeType: 'image/png', buffer: Buffer.from(source) })
  await expect(page.locator('.viewer-status [role=status]')).toContainText('1600 × 1200')
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  const downloaded = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const file = await downloaded
  const { readFile } = await import('node:fs/promises')
  const png = await readFile(await file.path())
  expect(png.readUInt32BE(16)).toBe(2400)
  expect(png.readUInt32BE(20)).toBe(1800)
})
