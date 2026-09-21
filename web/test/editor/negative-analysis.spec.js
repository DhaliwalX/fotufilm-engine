import { test, expect } from '@playwright/test'

test('maximum-size float negative analysis fits the worker protocol without reducing precision', async ({ page }) => {
  await page.route('**/negative-analysis-test', route => route.fulfill({
    contentType: 'text/html', body: '<!doctype html><title>Negative analysis</title>',
  }))
  await page.goto('/negative-analysis-test')
  const result = await page.evaluate(async () => {
    const { analyseNegative } = await import('/src/negative-conversion.js')
    const { LinearImage } = await import('/src/linear-image.js')
    const size = 512, pixels = new Float32Array(size * size * 4)
    const planes = [[], [], []]
    for (let i = 0; i < size * size; i++) {
      for (let c = 0; c < 3; c++) {
        pixels[i * 4 + c] = ((i * 7919 + c * 997) % 65535 + 1) / 65536
        planes[c].push(pixels[i * 4 + c])
      }
      pixels[i * 4 + 3] = 1
    }
    const oldPayloadSize = JSON.stringify({ planes }).length
    const image = new LinearImage({ pixels, width: size, height: size })
    const color = await analyseNegative(image)
    const mono = await analyseNegative(image, true)
    return { oldPayloadSize, color, mono }
  })
  expect(result.oldPayloadSize).toBeGreaterThan(8 * 1024 * 1024)
  for (const plan of [result.color, result.mono]) {
    expect(plan.parameters).toHaveLength(8)
    expect(plan.parameters.every(Number.isFinite)).toBe(true)
    for (let c = 0; c < 3; c++) expect(plan.parameters[c + 3]).toBeGreaterThan(plan.parameters[c])
  }
})
