#!/usr/bin/env node
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../web/package.json', import.meta.url))
const { chromium, expect } = require('@playwright/test')
const browser = await chromium.launch({channel:'chrome'})
try {
  const page = await browser.newPage()
  const errors = []; page.on('pageerror', e => errors.push(e.message))
  await page.goto(process.argv[2] || 'http://127.0.0.1:5173/')
  await expect(page.getByRole('button',{name:'More options',exact:true})).toBeVisible()
  for (const kind of ['color','mono']) {
    const fixture = JSON.parse(await readFile(new URL(`../build/negative-reference/automatic-${kind}.json`,import.meta.url),'utf8'))
    const report = await page.evaluate(async fixture => {
      const {loadFilmProfile} = await import('/src/film-profile.js')
      const {convertNegative} = await import('/src/negative-conversion.js')
      const {LinearImage} = await import('/src/linear-image.js')
      const plan = JSON.parse(new TextDecoder().decode(await loadFilmProfile(fixture.request)))
      const pixels = new Float32Array(fixture.width * fixture.height * 4)
      for(let i=0;i<fixture.width * fixture.height;i++) {
        for(let c=0;c<3;c++) pixels[4*i+c]=fixture.input[c][i]
        pixels[4*i+3]=1
      }
      const image = new LinearImage({pixels, width:fixture.width, height:fixture.height})
      const result = {plan, comparisons:{}}
      for(const preferGpu of [false,true]) {
        const output = await convertNegative(image,plan,{preferGpu})
        let error=0
        for(let i=0;i<pixels.length;i++) {
          const v=output.image.linear.data[i]
          if(!Number.isFinite(v))throw new Error('Nonfinite output')
          error=Math.max(error,Math.abs(v-fixture.expected[i]))
        }
        result.comparisons[preferGpu?'gpu':'cpu']={backend:output.backend,error}
      }
      const controller = new AbortController()
      const cancelled = convertNegative(image,plan,{signal:controller.signal})
      controller.abort()
      try {await cancelled; result.cancel='failed'} catch(e) {result.cancel=e.name}
      return result
    },fixture)
    assert.equal(report.plan.parameters.length,8)
    report.plan.parameters.forEach((v,i)=>assert.ok(Math.abs(v-fixture.plan.parameters[i])<1e-6))
    assert.equal(report.comparisons.gpu.backend,'webgpu')
    assert.equal(report.comparisons.cpu.backend,'cpu')
    assert.ok(report.comparisons.cpu.error<2e-5,JSON.stringify(report))
    assert.ok(report.comparisons.gpu.error<2e-5,JSON.stringify(report))
    assert.equal(report.cancel,'AbortError')
    console.log(kind,report)
  }
  const fixture = await readFile(new URL('../build/tiff-fixtures/rgb16-None.tiff',import.meta.url))
  await page.getByRole('button',{name:'More options',exact:true}).click()
  await page.getByRole('button',{name:'Import Scanned Negative…',exact:true}).click()
  const dialog=page.getByRole('dialog',{name:'Import Scanned Negative'})
  await dialog.locator('input[type=file]').setInputFiles({name:'negative.tiff',mimeType:'image/tiff',buffer:fixture})
  await expect(dialog.getByRole('button',{name:'Import Positive',exact:true})).toBeEnabled({timeout:60000})
  await expect(dialog.locator('img')).toHaveAttribute('alt','Converted positive preview')
  await dialog.getByRole('button',{name:'Show Negative',exact:true}).click()
  await expect(dialog.locator('img')).toHaveAttribute('alt','Original negative')
  await dialog.getByRole('button',{name:'Import Positive',exact:true}).click()
  await expect(dialog).not.toBeVisible({timeout:60000})
  await expect(page.locator('.viewer-status > [role=status]')).toContainText('70 × 45',{timeout:60000})
  assert.deepEqual(errors,[])
  console.log('Automatic negative: native/WASI/CPU/WebGPU, tile boundaries, cancellation and TIFF import UI passed')
} finally {await browser.close()}
