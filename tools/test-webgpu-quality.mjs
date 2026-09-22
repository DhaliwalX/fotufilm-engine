// Usage: node tools/test-webgpu-quality.mjs URL REPORT.json
import { chromium } from '../web/node_modules/playwright/index.mjs'
import { writeFile } from 'node:fs/promises'
const [url = 'http://127.0.0.1:5173/test/quality.html', output] =
  process.argv.slice(2)
const browser = await chromium.launch({ channel: 'chrome', headless: false })
try {
  const page = await browser.newPage()
  await page.goto(url)
  await page.waitForFunction(
    () => /WebGPU quality — (PASS|FAIL|ERROR)/.test(document.title),
    null,
    { timeout: 600_000 },
  )
  const result = JSON.parse(await page.locator('#report').textContent())
  if (output) await writeFile(output, JSON.stringify(result, null, 2) + '\n')
  console.log(await page.title())
  for (const row of result.results || [])
    if (!row.pass) console.log(JSON.stringify(row))
  if (result.error) console.error(result.error)
  if (!result.results?.length || result.results.some((row) => !row.pass))
    process.exitCode = 1
} finally {
  await browser.close()
}
