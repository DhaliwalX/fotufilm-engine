// Run against a development server after building the runtime. Frame zero is cold;
// compare the median of the remaining frames. CPU fallback is never GPU coverage.
import { chromium } from '../web/node_modules/playwright/index.mjs'
import { writeFile } from 'node:fs/promises'
const browser = await chromium.launch({ channel: 'chrome', headless: false })
try {
  const page = await browser.newPage()
  page.on('console', (message) => {
    if (message.type() === 'error' || message.text().startsWith('BENCH'))
      console.log(message.text())
  })
  await page.goto(process.argv[2] || 'http://127.0.0.1:5173/')
  const report = await page.evaluate(async () => {
    const { assetUrl, loadPack, normalPack, WebgpuDeveloper, pixelSource } =
      await import('/src/engine.js')
    const { relatedAssetUrl } = await import('/src/runtime-assets.js')
    const { nativeFramePack } = await import('/test/quality/fixture.js')
    const adapter = await navigator.gpu?.requestAdapter()
    if (!adapter) throw new Error('An actual WebGPU adapter is required')
    const info = Object.fromEntries(
      ['vendor', 'architecture', 'device', 'description'].map((key) => [
        key,
        adapter.info[key],
      ]),
    )
    const url = assetUrl('fotufilm-webgpu.mjs')
    const { default: factory } = await import(url)
    const module = await factory({
      locateFile: (name) => relatedAssetUrl(name, url),
    })
    const report = { adapter: info, runtime: url, results: [] }
    for (const id of [null, 'gold200']) {
      const pack = id
        ? await loadPack(assetUrl(`packs/${id}.pack`))
        : normalPack()
      const developer = new WebgpuDeveloper(module, pack)
      try {
        for (const [width, height] of [
          [960, 540],
          [1600, 900],
          [1920, 1080],
        ]) {
          const pixels = new Float32Array(width * height * 4)
          for (let y = 0; y < height; y++)
            for (let x = 0; x < width; x++) {
              const i = (y * width + x) * 4
              pixels[i] = 0.01 + (1.2 * x) / width
              pixels[i + 1] = 0.01 + (0.8 * y) / height
              pixels[i + 2] = 0.1 + 0.5 * (1 - x / width)
              pixels[i + 3] = 1
            }
          const source = pixelSource({ width, height, data: pixels }),
            frames = []
          for (let run = 0; run < 7; run++) {
            const start = performance.now()
            const result = await developer.develop(source, { grain: 1 })
            frames.push({
              wall: performance.now() - start,
              kernel: result.elapsed,
            })
          }
          if (id === 'gold200' && width === 1600)
            report.nativeFixture = nativeFramePack(developer)
          const row = { kind: 'webgpu', id, width, height, frames }
          report.results.push(row)
          console.log('BENCH ' + JSON.stringify(row))
        }
      } finally {
        developer.dispose()
      }
    }
    return report
  })
  const path = process.argv[3] || 'build/webgpu-performance.json'
  await writeFile(path + '.pack', Buffer.from(report.nativeFixture, 'base64'))
  delete report.nativeFixture
  await writeFile(path, JSON.stringify(report, null, 2) + '\n')
} finally {
  await browser.close()
}
