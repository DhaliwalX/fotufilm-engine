import { test, expect } from '@playwright/test'

test('queued edits keep the active operation visible and replace the pending edit', async ({ page }) => {
  await page.goto('/')
  const status = page.locator('.viewer-status > [role=status]')
  await page.getByRole('button', { name: 'Open sample chart' }).click()
  await expect(status).toContainText(/1600 × 1000 · \d+ ms/)
  await page.getByRole('tab', { name: 'Light & Color', exact: true }).click()
  // Hold one real render before it starts to make the queue deterministic.
  await page.evaluate(async () => {
    const { RenderSession } = await import('/src/render-session.js')
    const render = RenderSession.prototype.render
    let held = false
    RenderSession.prototype.render = async function (request) {
      if (!held && !request.background) {
        held = true
        window.reportHeldRender = request.onProgress
        request.onProgress('Measuring local highlights and shadows')
        await new Promise((resolve) => { window.releaseHeldRender = resolve })
      }
      return render.call(this, request)
    }
  })
  const exposure = page.getByRole('spinbutton', { name: 'Exposure value', exact: true })
  await exposure.fill('0.5')
  await exposure.press('Tab')
  await expect(status).toContainText('Measuring local highlights and shadows')
  await exposure.fill('1')
  await exposure.press('Tab')
  await expect(status).toContainText('Next: Exposure +1 EV')
  await exposure.fill('1.25')
  await exposure.press('Tab')
  await expect(status).toContainText('Measuring local highlights and shadows · Next: Exposure +1.25 EV')
  await page.evaluate(() => window.reportHeldRender('Encoding preview image'))
  await expect(status).toContainText('Encoding preview image · Next: Exposure +1.25 EV')
  await exposure.press('Tab')
  await expect(status).toContainText('1600px preview')
  await page.evaluate(() => window.releaseHeldRender())
  await expect(status).toContainText(/1600 × 1000 · \d+ ms/)
  await expect(status).not.toContainText('Next:')
})

test('export progress follows actual preparation, render tiles and encoding', async ({ page }) => {
  await page.goto('/')
  const report = await page.evaluate(async () => {
    const { RenderSession } = await import('/src/render-session.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const image = document.createElement('canvas')
    image.width = 2048
    image.height = 1200
    image.getContext('2d').fillRect(0, 0, image.width, image.height)
    const session = new RenderSession(), progress = []
    try {
      const result = await session.render({ image, edit: defaultEdit(), stock: 'gold200',
        maxEdge: Infinity, comparison: false, purpose: 'export',
        onProgress: (stage) => progress.push(stage) })
      return { progress, width: result.width, height: result.height }
    } finally {
      await session.dispose()
    }
  })
  expect(report.width).toBe(2048)
  expect(report.height).toBe(1200)
  expect(report.progress).toContain('Preparing crop and image pixels')
  const tiles = report.progress.filter((stage) => stage.startsWith('Applying light and color · tile'))
  expect(tiles.length).toBeGreaterThan(1)
  expect(tiles[0]).toContain(`tile 1 of ${tiles.length}`)
  expect(tiles.at(-1)).toContain(`tile ${tiles.length} of ${tiles.length}`)
  expect(tiles.at(-1)).toContain('2048×1200 export')
  expect(report.progress.at(-1)).toBe('Encoding export image')
})
