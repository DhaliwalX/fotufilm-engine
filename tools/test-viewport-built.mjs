#!/usr/bin/env node
// Verify bounded detail and deep-color delivery through the shipped bundle.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { deflateSync } from 'node:zlib'
import { png16 } from '../web/test/editor/png-fixture.js'
import { iccProfile } from '../web/src/color-profiles.js'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium, expect } = require('@playwright/test')
const base = new URL(process.argv[2] || 'http://127.0.0.1:5758/')
const browser = await chromium.launch({ channel: 'chrome' })
try {
  const page = await browser.newPage({
    ignoreHTTPSErrors: true,
    deviceScaleFactor: 2,
    viewport: { width: 1440, height: 960 },
  })
  const errors = [],
    requests = []
  page.on('pageerror', (error) => errors.push(error.message))
  page.on('request', (request) => requests.push(request.url()))
  await page.goto(base.href)
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    /\d+ × \d+/,
    { timeout: 60000 },
  )
  const width = 2048,
    height = 1024
  const buffer = png16({
    width,
    height,
    sample: (x) => {
      const v = 12000 + x * 20
      return [v, v, v, 65535]
    },
    chunks: [
      [
        'iCCP',
        Buffer.concat([
          Buffer.from('Display P3\0\0'),
          deflateSync(iccProfile('display-p3')),
        ]),
      ],
    ],
  })
  await page
    .locator('input[type=file][multiple]')
    .setInputFiles({ name: 'Deep gradient.png', mimeType: 'image/png', buffer })
  await expect(page.locator('.document-name')).toHaveText('Deep gradient.png')
  await expect(page.locator('.viewport-detail')).toBeVisible({ timeout: 60000 })
  await expect(page.locator('.backend-label')).toHaveText('WebGPU', {
    timeout: 60000,
  })
  await page.getByLabel('Photo preview', { exact: true }).hover()
  for (let i = 0; i < 15; i++) {
    await page.mouse.wheel(0, -60)
    await page.waitForTimeout(20)
  }
  const detail = page.locator('.viewport-detail')
  await expect(detail).toBeVisible({ timeout: 60000 })
  const region = await detail.evaluate((img) => ({
    width: +img.dataset.renderWidth,
    height: +img.dataset.renderHeight,
    fullWidth: +img.dataset.frameWidth,
    fullHeight: +img.dataset.frameHeight,
    viewportWidth: img.closest('.canvas-area').clientWidth * devicePixelRatio,
    viewportHeight: img.closest('.canvas-area').clientHeight * devicePixelRatio,
    backend: img.dataset.backend,
  }))
  assert.equal(region.backend, 'webgpu')
  assert.ok(region.fullWidth > region.width * 2)
  assert.ok(
    region.width <= region.viewportWidth + 2 &&
      region.height <= region.viewportHeight + 2,
  )
  await page.getByRole('tab', { name: 'Print', exact: true }).click()
  await page.getByRole('button', { name: 'Export Photo…', exact: true }).click()
  await page.getByLabel('Format', { exact: true }).selectOption('image/tiff')
  const pending = page.waitForEvent('download', { timeout: 60000 })
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  const file = await pending,
    bytes = await readFile(await file.path()),
    tags = new Map()
  for (let i = 0; i < bytes.readUInt16LE(8); i++) {
    const at = 10 + i * 12
    tags.set(bytes.readUInt16LE(at), {
      count: bytes.readUInt32LE(at + 4),
      value: bytes.readUInt32LE(at + 8),
    })
  }
  assert.deepEqual([tags.get(256).value, tags.get(257).value], [width, height])
  assert.equal(bytes.readUInt16LE(tags.get(258).value), 16)
  const profile = tags.get(34675)
  assert.deepEqual(
    bytes.subarray(profile.value, profile.value + profile.count),
    Buffer.from(iccProfile('display-p3')),
  )
  const strips = tags.get(273),
    offset =
      strips.count === 1 ? strips.value : bytes.readUInt32LE(strips.value)
  const levels = new Set(
    Array.from({ length: width }, (_, x) => bytes.readUInt16LE(offset + x * 8)),
  )
  assert.ok(
    levels.size > 1500,
    `Only ${levels.size} levels survived 16-bit PNG → TIFF`,
  )
  assert.ok(
    requests.some((url) =>
      url.startsWith(new URL('png/decoder.wasm', base).href),
    ),
  )
  assert.deepEqual(errors, [])
  console.log(
    JSON.stringify({
      url: base.href,
      region,
      exportSize: [width, height],
      bits: 16,
      profile: 'Display P3',
      levels: levels.size,
      errors,
    }),
  )
} finally {
  await browser.close()
}
