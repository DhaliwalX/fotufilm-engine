import { test, expect } from '@playwright/test'

test('Halide Normal agrees with the reference across all light and grade controls', async ({
  page,
}) => {
  await page.goto('/')
  const report = await page.evaluate(async () => {
    const { createNormalDeveloper, developNormalReference, pixelSource } = await import(
      '/src/engine.js'
    )
    const { defaultEdit } = await import('/src/editor-state.js')
    const developer = await createNormalDeveloper()
    if (!developer) throw new Error('Build the Halide Normal kernel before testing.')
    const width = 240,
      height = 160,
      data = new Float32Array(width * height * 4)
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4
        data[i] = x / width
        data[i + 1] = y / height
        data[i + 2] = 0.25
        data[i + 3] = 1
      }
    const source = pixelSource({ width, height, data }),
      controls = {
        ...defaultEdit().params,
        ev: 0.6,
        shadows: 0.4,
        highlights: -0.5,
        localTone: true,
        temperature: 5300,
        tint: 10,
        saturation: 1.2,
        vibrance: 0.15,
        gradeShadowsWarmth: 0.2,
        gradeMidtonesTint: -0.1,
        gradeHighlightsLevel: 0.2,
        gradeSpace: true,
      }
    try {
      const a = await developer.develop(source, controls),
        b = await developNormalReference(source, controls)
      const deltas = a.pixels.map((v, i) => Math.abs(v - b.pixels[i]))
      return {
        peak: deltas.reduce((peak, value) => Math.max(peak, value), 0),
        mean: deltas.reduce((a, b) => a + b, 0) / deltas.length,
      }
    } finally {
      developer.dispose()
    }
  })
  console.log('Halide Normal/reference:', report)
  expect(report.peak).toBeLessThanOrEqual(1)
  expect(report.mean).toBeLessThan(0.01)
})

for (const stock of [null, 'Gold 200'])
  test(`continuous edits publish frames before release: ${stock || 'Normal'}`, async ({ page }) => {
    await page.goto('/')
    await page.getByRole('button', { name: 'Open sample chart' }).click()
    await expect(page.locator('.viewer-status > [role=status]')).toContainText('1600 × 1000')
    if (stock) {
      await page.getByRole('searchbox').fill(stock)
      await page.getByTitle(stock, { exact: true }).click()
      await expect(page.locator('.backend-label')).toHaveText('WebGPU')
      await expect(page.locator('.viewer-status > [role=status]')).toContainText('1600 × 1000')
    }
    await page.getByRole('tab', { name: 'Light & Color' }).click()
    await page.evaluate(() => {
      window.previewFrames = []
      new MutationObserver(() => window.previewFrames.push(performance.now())).observe(
        document.querySelector('.photo-plane img'),
        { attributes: true, attributeFilter: ['src'] },
      )
    })
    const drag = async (name) => {
      const slider = page.getByRole('slider', { name, exact: true })
      await slider.scrollIntoViewIfNeeded()
      const box = await slider.locator('..').boundingBox()
      const beforeSize = await page.locator('.photo-plane').boundingBox()
      await page.evaluate(() => {
        window.previewFrames = []
      })
      await page.mouse.move(box.x + box.width * 0.3, box.y + box.height / 2)
      await page.mouse.down()
      for (let i = 0; i < 40; i++) {
        await page.mouse.move(box.x + box.width * (0.3 + i / 100), box.y + box.height / 2)
        await page.waitForTimeout(25)
      }
      const frames = await page.evaluate(() => window.previewFrames)
      console.log(`${stock || 'Normal'} ${name} frames during drag:`, frames.length)
      expect(frames.length).toBeGreaterThanOrEqual(8)
      const duringSize = await page.locator('.photo-plane').boundingBox()
      expect(Math.abs(duringSize.width - beforeSize.width)).toBeLessThanOrEqual(2)
      await page.mouse.up()
      await expect(page.locator('.viewer-status > [role=status]')).toContainText('1600 × 1000')
    }
    for (const name of ['Exposure', 'Shadows', 'Temperature']) await drag(name)
    if (stock) {
      await page.getByRole('tab', { name: 'Film', exact: true }).click()
      await drag('Grain')
    }
    await page.getByRole('tab', { name: 'Crop', exact: true }).click()
    await expect(page.locator('.viewer-status > [role=status]')).toContainText('1600 × 1000')
    await drag('Straighten')
    await expect(page.getByRole('button', { name: 'Preview crop', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
    await expect(page.getByLabel('Crop selection')).toBeHidden()
  })
