import { test, expect } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'

for (const stockID of ['gold200', 'hp5plus400'])
  test(`every ${stockID} output medium reconstructs the native pack and renders on CPU and WebGPU`, async ({
    page,
  }, info) => {
    test.setTimeout(180000)
    const media = JSON.parse(readFileSync('public/packs/media.json')).find((s) => s.id === stockID)
    const expected = {}
    for (const choice of media.choices) {
      const path = info.outputPath(`${choice.id}.pack`)
      execFileSync(resolve('../.build/release/fotufilm'), [
        '--dump-wasm-pack',
        path,
        '--stock',
        stockID,
        '--paper',
        choice.id,
        '--pack-size',
        '1600x900',
      ])
      expected[choice.id] = createHash('sha256').update(readFileSync(path)).digest('hex')
    }
    await page.goto('/')
    const report = await page.evaluate(async (stockID) => {
      const { RenderSession, loadStockIndex } = await import('/src/render-session.js')
      const { pixelSource, createDeveloper, createCpuDeveloper } = await import('/src/engine.js')
      const { defaultEdit } = await import('/src/editor-state.js')
      const stock = (await loadStockIndex()).find((s) => s.id === stockID)
      const session = new RenderSession()
      const data = new Uint8ClampedArray(160 * 100 * 4)
      for (let i = 0; i < data.length; i += 4) {
        data[i] = (i / 4) % 256
        data[i + 1] = ((i / 4) * 7) % 256
        data[i + 2] = 97
        data[i + 3] = 255
      }
      const source = pixelSource({ data, width: 160, height: 100 }),
        results = []
      let gpu, cpu
      try {
        for (const choice of stock.media) {
          const entry = await session.pack(stock.id, choice.id)
          gpu ??= await createDeveloper(entry.pack)
          cpu ??= await createCpuDeveloper(entry.pack)
          gpu.usePack(entry.pack)
          cpu.usePack(entry.pack)
          const controls = { ...defaultEdit().params, grain: 0, ev: 0.4 }
          const a = await gpu.develop(source, controls),
            b = await cpu.develop(source, controls)
          const deltas = a.pixels.map((v, i) => Math.abs(v - b.pixels[i]))
          const hash = async (bytes) =>
            Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
              .map((v) => v.toString(16).padStart(2, '0'))
              .join('')
          const stages = await session.stages(stock.id, choice.id)
          results.push({
            id: choice.id,
            hash: await hash(entry.pack.bytes),
            output: await hash(a.pixels),
            peak: deltas.reduce((a, b) => Math.max(a, b), 0),
            stages: stages.length,
            backend: gpu.backend,
          })
        }
      } finally {
        gpu?.dispose()
        cpu?.dispose()
        await session.dispose()
      }
      return results
    }, stockID)
    console.log(
      `${stockID} output medium parity:`,
      report.map(({ id, peak }) => ({ id, peak })),
    )
    for (const result of report) {
      expect(result.hash).toBe(expected[result.id])
      expect(result.backend).toBe('webgpu')
      expect(result.peak).toBeLessThanOrEqual(1)
      expect(result.stages).toBeGreaterThan(5)
    }
    const outputs = Object.fromEntries(report.map((r) => [r.id, r.output]))
    expect(outputs.screen).not.toBe(outputs.negative)
    expect(outputs['ektacolor-edge']).not.toBe(outputs.screen)
  })

test('output selection updates preview, undo, saved edits, export and reversal choices', async ({
  page,
}) => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Open sample chart' }).click()
  const ready = () =>
    expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/)
  await ready()
  await page.getByRole('searchbox').fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await ready()
  const select = page.getByRole('combobox', { name: 'Output medium', exact: true })
  await expect(select).toContainText('Kodak Ektacolor Edge')
  const before = await page.locator('.photo-plane > img').getAttribute('src')
  await select.click()
  await page.getByRole('option', { name: 'Lab Scan', exact: true }).click()
  await ready()
  expect(await page.locator('.photo-plane > img').getAttribute('src')).not.toBe(before)
  await page.getByRole('button', { name: 'Undo (⌘Z)', exact: true }).click()
  await expect(select).toContainText('Kodak Ektacolor Edge')
  await page.getByRole('button', { name: 'Redo (⇧⌘Z)', exact: true }).click()
  await expect(select).toContainText('Lab Scan')
  await ready()
  await page.getByRole('button', { name: 'More options' }).click()
  const saved = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Save edits…', exact: true }).click()
  expect(JSON.parse(readFileSync(await (await saved).path(), 'utf8')).edit.medium).toBe('lab-scan')
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  const download = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const file = await download
  expect(file.suggestedFilename()).toContain('lab-scan')
  expect(readFileSync(await file.path()).readUInt32BE(16)).toBe(1600)
  await page.getByRole('searchbox').fill('Velvia 50')
  await page.getByTitle('Velvia 50', { exact: true }).click()
  await ready()
  await expect(select).toContainText('Digital Reference')
  await select.click()
  await expect(page.getByRole('option')).toHaveCount(1)
  await expect(page.getByRole('option')).toHaveText('Digital Reference')
  await expect(page.getByText('43 films installed', { exact: true })).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Profile licence' })).toHaveCount(0)
})
