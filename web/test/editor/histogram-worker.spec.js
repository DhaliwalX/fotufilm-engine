import { test, expect } from '@playwright/test'
import { histogramStatistics } from '../../src/histogram-model.js'

for (const mode of ['native', 'missing attributes', 'sRGB readback']) {
  test(`histogram worker respects sample colours with ${mode}`, async ({ page }) => {
    await page.goto(process.env.FOTUFILM_TEST_URL || '/')
    for (const colorSpace of ['srgb', 'display-p3']) {
      const actual = await page.evaluate(async ({ mode, colorSpace, workerURL }) => {
        const canvas = new OffscreenCanvas(4, 2)
        const context = canvas.getContext('2d', { colorSpace })
        context.fillStyle = colorSpace === 'display-p3' ? 'color(display-p3 1 0 0)' : '#ff0000'
        context.fillRect(0, 0, 4, 2)
        const output = await canvas.convertToBlob({ type: 'image/png' })
        const script = `
          const prototype = Object.getPrototypeOf(new OffscreenCanvas(1, 1).getContext('2d'));
          if (${JSON.stringify(mode)} !== 'native')
            Object.defineProperty(prototype, 'getContextAttributes', { value: undefined, configurable: true });
          if (${JSON.stringify(mode)} === 'sRGB readback') {
            const read = prototype.getImageData;
            prototype.getImageData = function(x, y, w, h) {
              return read.call(this, x, y, w, h, { colorSpace: 'srgb' });
            };
          }
          await import(${JSON.stringify(workerURL || new URL('/src/histogram.worker.js', location.href).href)});
          self.postMessage({ ready: true });
        `
        const url = URL.createObjectURL(new Blob([script], { type: 'text/javascript' }))
        const worker = new Worker(url, { type: 'module' })
        try {
          return await new Promise((resolve, reject) => {
            worker.onerror = event => reject(new Error(event.message))
            worker.onmessage = ({ data }) => {
              if (data.ready) worker.postMessage({ generation: 7, output, colorSpace })
              else if (data.error) reject(new Error(data.error))
              else resolve(data)
            }
          })
        } finally {
          worker.terminate()
          URL.revokeObjectURL(url)
        }
      }, { mode, colorSpace, workerURL: process.env.FOTUFILM_HISTOGRAM_WORKER_URL })
      expect(actual.generation).toBe(7)
      const expected = histogramStatistics({
        data: new Uint8ClampedArray(Array.from({ length: 8 }, () => [255, 0, 0, 255]).flat()),
        colorSpace: mode === 'sRGB readback' ? 'srgb' : colorSpace,
      })
      expect(actual.analysis.count).toBe(expected.count)
      for (const field of ['bins', 'chroma', 'oklab'])
        expect(actual.analysis[field].map(bins => Array.from(bins))).toEqual(expected[field].map(bins => Array.from(bins)))
      expect(Array.from(actual.analysis.luma)).toEqual(Array.from(expected.luma))
    }
  })
}
