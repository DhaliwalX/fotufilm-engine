import { test, expect } from '@playwright/test'

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
