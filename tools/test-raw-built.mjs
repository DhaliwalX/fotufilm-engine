#!/usr/bin/env node
// Run against a served production build, including builds published under a subdirectory.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { makeDNG } from '../web/test/editor/raw-fixture.js'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium } = require('@playwright/test')
const base = new URL(process.argv[2] || 'http://127.0.0.1:5757/')
const browser = await chromium.launch({ channel: 'chrome' })
try {
  const page = await browser.newPage()
  const errors = [], decoderRequests = [], mediumRequests = [], sceneRequests = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('request', request => {
    if (request.url().includes('/packs/scene/')) sceneRequests.push(request.url())
    if (request.url().includes('/raw/')) decoderRequests.push(request.url())
    if (request.url().includes('/packs/media/')) mediumRequests.push(request.url())
  })
  await page.goto(base.href)
  const requested = (requests, name) => requests.find(url => {
    const actual = new URL(url), expected = new URL(name, base)
    return actual.origin === expected.origin && actual.pathname === expected.pathname
  })
  await page.locator('input[type=file][multiple]').setInputFiles({ name: 'linear.DNG',
    mimeType: '', buffer: Buffer.from(makeDNG({ width: 2001, height: 1201, mosaic: false })) })
  await page.waitForFunction(() => /1600 × 960/.test(document.querySelector('.viewer-status > [role=status]')?.textContent), null, { timeout: 30000 })
  assert.match(await page.locator('.pixel-readout').innerText(), /RAW/)
  const decoderModule = requested(decoderRequests, 'raw/decoder.mjs')
  assert.ok(decoderModule)
  const revision = new URL(decoderModule).searchParams.get('v')
  assert.ok(revision, 'production runtime must have a content revision')
  for (const name of ['raw/decoder.wasm', 'raw/camera-profiles.json']) {
    const url = requested(decoderRequests, name)
    assert.ok(url, `${name} was requested`)
    assert.equal(new URL(url).searchParams.get('v'), revision)
  }
  assert.deepEqual(errors, [])
  await page.getByRole('searchbox').fill('Gold 200')
  await page.getByTitle('Gold 200', { exact: true }).click()
  await page.getByRole('combobox', { name: 'Output medium', exact: true }).click()
  await page.getByRole('option', { name: 'Lab Scan', exact: true }).click()
  await page.waitForFunction(() => /1600 × 960/.test(document.querySelector('.viewer-status > [role=status]')?.textContent), null, { timeout: 60000 })
  assert.ok(requested(mediumRequests, 'packs/media/gold200/lab-scan.pack.delta'))
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  for (const name of ['packs/scene/index.json', 'packs/scene/geometry.spectra']) {
    const url = requested(sceneRequests, name)
    assert.ok(url, `${name} was requested`)
    assert.equal(new URL(url).searchParams.get('v'), revision)
  }
  const downloaded = page.waitForEvent('download')
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const file = await downloaded
  assert.match(file.suggestedFilename(), /gold200-lab-scan/)
  const exported = await readFile(await file.path())
  assert.equal(exported.readUInt32BE(16), 2001)
  assert.equal(exported.readUInt32BE(20), 1201)
  const png = await page.evaluate(async () => {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 64
    canvas.getContext('2d').fillRect(0, 0, 64, 64)
    return Array.from(new Uint8Array(await (await new Promise(resolve => canvas.toBlob(resolve))).arrayBuffer()))
  })
  await page.locator('input[type=file][multiple]').setInputFiles([
    { name: 'second.DNG', mimeType: '', buffer: Buffer.from(makeDNG()) },
    { name: 'ordinary.png', mimeType: 'image/png', buffer: Buffer.from(png) },
  ])
  await page.getByRole('button', { name: 'Select ordinary.png', exact: true }).click()
  await page.waitForFunction(() => /64 × 64/.test(document.querySelector('.viewer-status > [role=status]')?.textContent))
  assert.doesNotMatch(await page.locator('.pixel-readout').innerText(), /RAW/)
  await page.getByRole('button', { name: 'Select linear.DNG', exact: true }).click()
  await page.waitForFunction(() => /1600 × 960/.test(document.querySelector('.viewer-status > [role=status]')?.textContent))
  assert.deepEqual(errors, [])
  console.log('Built editor: RAW decoder and output-medium URLs, full-resolution export and mixed imports pass.')
} finally {
  await browser.close()
}
