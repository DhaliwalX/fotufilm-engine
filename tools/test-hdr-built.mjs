#!/usr/bin/env node
// Verify bundled workers and revisioned decoder URLs against a static production
// build. Accept a subdirectory URL to catch asset-path regressions too.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium } = require('@playwright/test')
const base = new URL(process.argv[2] || 'http://127.0.0.1:5757/')
const browser = await chromium.launch({ channel: 'chrome' })
try {
  const page = await browser.newPage(), errors = [], requests = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('request', request => requests.push(request.url()))
  await page.goto(base.href)
  // The default demo uses the shared EXR import worker.
  await page.waitForFunction(() => /\d+ × \d+/.test(document.querySelector('.viewer-status > [role=status]')?.textContent), null, { timeout: 60000 })
  const file = await readFile(new URL('../build/ultrahdr/fixtures/rotated.jpg', import.meta.url))
  await page.locator('input[type=file][multiple]').setInputFiles({ name: 'HDR.jpg', mimeType: 'image/jpeg', buffer: file })
  await page.waitForFunction(() => /64 × 96/.test(document.querySelector('.viewer-status > [role=status]')?.textContent), null, { timeout: 60000 })
  assert.match(await page.locator('.pixel-readout').innerText(), /HDR/)
  const runtimeURLs = ['hdr/decoder.mjs', 'hdr/decoder.wasm'].map(name => {
    const expected = new URL(name, base)
    const request = requests.find(value => new URL(value).pathname === expected.pathname)
    assert.ok(request, `${name} must load under the configured base path`)
    return new URL(request)
  })
  assert.ok(runtimeURLs[0].searchParams.get('v'))
  assert.equal(runtimeURLs[0].searchParams.get('v'), runtimeURLs[1].searchParams.get('v'))
  await page.getByRole('tab', { name: 'Expose', exact: true }).click()
  await page.getByRole('combobox', { name: 'Highlights', exact: true }).click()
  await page.getByRole('option', { name: 'Standard Range', exact: true }).click()
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  const download = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const png = await readFile(await (await download).path())
  assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [64, 96])
  assert.deepEqual(errors, [])
  console.log('Production EXR/HDR workers, orientation, source interpretation, full-size export and revisioned asset paths passed.')
} finally { await browser.close() }
