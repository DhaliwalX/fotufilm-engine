import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'

test('selective edits preview, undo, save, and export without exporting the mask', async ({
  page,
}) => {
  await page.route('**/packs/index.json*', (route) =>
    route.fulfill({ json: [{ id: 'gold200', name: 'Gold 200' }] }),
  )
  await page.route('**/packs/media.json*', (route) =>
    route.fulfill({
      json: [
        {
          id: 'gold200',
          default: 'screen',
          choices: [{ id: 'screen', name: 'Digital Reference' }],
        },
      ],
    }),
  )
  await page.goto('/')
  const data = await page.evaluate(() => {
    const canvas = document.createElement('canvas')
    canvas.width = 120
    canvas.height = 80
    const ctx = canvas.getContext('2d')
    ctx.fillStyle = '#703030'
    ctx.fillRect(0, 0, 60, 80)
    ctx.fillStyle = '#303070'
    ctx.fillRect(60, 0, 60, 80)
    return canvas.toDataURL().split(',')[1]
  })
  await page
    .locator('input[type=file][multiple]')
    .setInputFiles({
      name: 'selection.png',
      mimeType: 'image/png',
      buffer: Buffer.from(data, 'base64'),
    })
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    '120 × 80',
  )
  const pixels = () =>
    page.locator('.photo-plane > img').evaluate((image) => {
      if (!image.complete || !image.naturalWidth) return [[-1], [-1]]
      const c = document.createElement('canvas')
      c.width = 120
      c.height = 80
      const ctx = c.getContext('2d')
      ctx.drawImage(image, 0, 0, 120, 80)
      return [
        Array.from(ctx.getImageData(25, 40, 1, 1).data),
        Array.from(ctx.getImageData(95, 40, 1, 1).data),
      ]
    })
  const before = await pixels()
  await page.getByRole('button', { name: 'Selective', exact: true }).click()
  await page
    .getByRole('button', { name: 'Sample a Point', exact: true })
    .click()
  const rect = await page.locator('.photo-plane').boundingBox()
  await page.mouse.click(rect.x + rect.width * 0.2, rect.y + rect.height * 0.5)
  await page
    .getByRole('spinbutton', { name: 'Exposure value', exact: true })
    .fill('1')
  await page
    .getByRole('spinbutton', { name: 'Exposure value', exact: true })
    .press('Tab')
  await expect
    .poll(async () => (await pixels())[0][0])
    .toBeGreaterThan(before[0][0])
  const selected = await pixels()
  expect(selected[1]).toEqual(before[1])
  await page.getByRole('button', { name: 'Undo (⌘Z)', exact: true }).click()
  await expect(
    page.getByRole('spinbutton', { name: 'Exposure value', exact: true }),
  ).toHaveValue('0')
  await page.getByRole('button', { name: 'Redo (⇧⌘Z)', exact: true }).click()
  await expect(
    page.getByRole('spinbutton', { name: 'Exposure value', exact: true }),
  ).toHaveValue('1')
  await page.getByRole('switch', { name: 'Show Mask', exact: true }).click()
  await expect.poll(async () => (await pixels())[0][0]).toBe(255)
  await page.getByRole('button', { name: 'More options', exact: true }).click()
  const savedPromise = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Save edits…', exact: true }).click()
  const saved = await savedPromise
  const edit = JSON.parse(await readFile(await saved.path(), 'utf8')).edit
  expect(edit.selective.params.ev).toBe(1)
  expect(edit.selective.sample).toHaveLength(3)
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  const exportPromise = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const exported = await exportPromise
  const png = await readFile(await exported.path())
  const exportPixel = await page.evaluate(async (data) => {
    const img = new Image()
    img.src = 'data:image/png;base64,' + data
    await img.decode()
    const canvas = document.createElement('canvas')
    canvas.width = 120
    canvas.height = 80
    const ctx = canvas.getContext('2d')
    ctx.drawImage(img, 0, 0)
    return Array.from(ctx.getImageData(25, 40, 1, 1).data)
  }, png.toString('base64'))
  expect(exportPixel).toEqual(selected[0])
})
