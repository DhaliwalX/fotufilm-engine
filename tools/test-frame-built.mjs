#!/usr/bin/env node
// Exercise native frame planning and compositing through the real, bundled app.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium, expect } = require('@playwright/test')
const base = new URL(process.argv[2] || 'http://127.0.0.1:5757/')
const browser = await chromium.launch({ channel: 'chrome' })
try {
  const page = await browser.newPage(), errors = [], requests = []
  page.on('pageerror', (e) => errors.push(e.message))
  page.on('request', (r) => requests.push(r.url()))
  await page.goto(base.href)
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/, { timeout: 60000 })
  await page.getByRole('searchbox', { name: 'Search films', exact: true }).fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await page.getByRole('tab', { name: 'Print', exact: true }).click()
  const picker = page.getByRole('combobox', { name: 'Frame', exact: true })
  await expect(picker).toBeEnabled({ timeout: 60000 })
  for (const name of ['Film Border', 'Emulsion Border', 'Portrait Post']) {
    await picker.click(); await page.getByRole('option', { name, exact: true }).click()
    await expect(picker).toContainText(name)
    await expect(page.locator('.viewer-status > [role=status]')).toContainText(/\d+ × \d+/, { timeout: 60000 })
    await page.getByRole('button', { name: 'Export Photo…', exact: true }).click()
    const text = await page.locator('.export-detail').first().innerText()
    const dimensions = text.match(/(\d+) × (\d+)/).slice(1).map(Number)
    const download = page.waitForEvent('download')
    await page.getByRole('button', { name: 'Export', exact: true }).click()
    const png = await readFile(await (await download).path())
    assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], dimensions)
    if (name === 'Portrait Post') assert.ok(Math.abs(dimensions[0] / dimensions[1] - .8) < .001)
  }
  const worker = requests.find((url) => /\/assets\/profile-worker-[^/]+\.js/.test(new URL(url).pathname))
  assert.ok(worker && new URL(worker).pathname.startsWith(base.pathname), 'Profile worker must be bundled below the deployment path')
  assert.ok(requests.some((url) => new URL(url).pathname === new URL('profile/builder.wasm', base).pathname))
  assert.deepEqual(errors, [])
  console.log('Production film, emulsion and posting frames, native profile worker, dimensions and full-size exports passed.')
} finally { await browser.close() }
