import { test, expect } from '@playwright/test'

test('maximum-size float negative analysis fits the worker protocol without reducing precision', async ({ page }) => {
  await page.route('**/negative-analysis-test', route => route.fulfill({
    contentType: 'text/html', body: '<!doctype html><title>Negative analysis</title>',
  }))
  await page.goto('/negative-analysis-test')
  const result = await page.evaluate(async () => {
    const { analyseNegative } = await import('/src/negative-conversion.js')
    const { LinearImage } = await import('/src/linear-image.js')
    const size = 512, pixels = new Float32Array(size * size * 4)
    const planes = [[], [], []]
    for (let i = 0; i < size * size; i++) {
      for (let c = 0; c < 3; c++) {
        pixels[i * 4 + c] = ((i * 7919 + c * 997) % 65535 + 1) / 65536
        planes[c].push(pixels[i * 4 + c])
      }
      pixels[i * 4 + 3] = 1
    }
    const oldPayloadSize = JSON.stringify({ planes }).length
    const image = new LinearImage({ pixels, width: size, height: size })
    const color = await analyseNegative(image)
    const mono = await analyseNegative(image, true)
    return { oldPayloadSize, color, mono }
  })
  expect(result.oldPayloadSize).toBeGreaterThan(8 * 1024 * 1024)
  for (const plan of [result.color, result.mono]) {
    expect(plan.parameters).toHaveLength(8)
    expect(plan.parameters.every(Number.isFinite)).toBe(true)
    for (let c = 0; c < 3; c++) expect(plan.parameters[c + 3]).toBeGreaterThan(plan.parameters[c])
  }
})

test('wide-gamut negative channels survive inversion on CPU and WebGPU', async ({ page }) => {
  await page.goto('/')
  const result = await page.evaluate(async () => {
    const { analyseNegative, convertNegative } = await import('/src/negative-conversion.js')
    const { LinearImage } = await import('/src/linear-image.js')
    const { INGEST_COLOR } = await import('/src/engine-constants.js')
    // Synthetic P3 orange samples crossing the sRGB blue boundary, over a tile boundary.
    const width = 640, height = 16, pixels = new Float32Array(width * height * 4)
    const matrix = INGEST_COLOR.linearDisplayP3ToRec2020
    let outside = 0
    for (let i=0;i<width*height;i++) {
      const t = (i % width) / (width-1), p3 = [.35+.4*t, .015+.18*t, .004+.018*t]
      const rgb = [0,1,2].map(c => matrix[c*3]*p3[0]+matrix[c*3+1]*p3[1]+matrix[c*3+2]*p3[2])
      if (-.0181508*rgb[0]-.1005789*rgb[1]+1.1187297*rgb[2] < 0) outside++
      pixels.set([...rgb,1],4*i)
    }
    const image = new LinearImage({pixels,width,height})
    const plan = await analyseNegative(image)
    const cpu = await convertNegative(image,plan,{preferGpu:false})
    const gpu = await convertNegative(image,plan,{preferGpu:true})
    let black=0,error=0,nonfinite=0
    for(let i=0;i<pixels.length;i+=4) {
      const a=cpu.image.linear.data,b=gpu.image.linear.data
      if(a[i]===0&&a[i+1]===0&&a[i+2]===0)black++
      for(let c=0;c<3;c++) {error=Math.max(error,Math.abs(a[i+c]-b[i+c]));if(!Number.isFinite(a[i+c])||!Number.isFinite(b[i+c]))nonfinite++}
    }
    return {outside,black,error,nonfinite,backend:gpu.backend,plan}
  })
  expect(result.outside).toBeGreaterThan(0)
  expect(result.black).toBe(0)
  expect(result.nonfinite).toBe(0)
  expect(result.backend).toBe('webgpu')
  expect(result.error).toBeLessThan(0.00002)
  expect(result.plan.parameters[2]).toBe(0)
})
