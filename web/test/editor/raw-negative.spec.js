import { test, expect } from '@playwright/test'
import { makeDNG } from './raw-fixture.js'

test('RAW negatives ignore photographic baseline and spectral corrections while preserving precision', async ({ page }) => {
  await page.goto('/')
  const fixtures = [0, 1].map(baselineExposure => Array.from(makeDNG({
    baselineExposure, orientation: 6, asShotNeutral: [0.5, 1, 0.625],
  })))
  const report = await page.evaluate(async fixtures => {
    const { decodeRaw } = await import('/src/raw-import.js')
    const decoded = []
    for (const negative of [true, false]) {
      for (const bytes of fixtures) {
        const progress = []
        const image = await decodeRaw(new File([new Uint8Array(bytes)], 'scan.dng'), {
          negative, onProgress: stage => progress.push(stage),
        })
        decoded.push({ width: image.naturalWidth, height: image.naturalHeight,
          scale: image.raw.sceneScale, profile: image.raw.profile,
          kelvin: image.raw.sceneKelvin, codes: new Set(image.raw.data).size,
          bits: image.raw.data.BYTES_PER_ELEMENT * 8,
          pixels: Array.from(image.raw.data), progress })
      }
    }
    return { negative: decoded.slice(0, 2).map(({ pixels, ...rest }) => rest),
      identical: decoded[0].pixels.every((value, i) => value === decoded[1].pixels[i]),
      ordinaryRatio: decoded[3].scale / decoded[2].scale,
      ordinaryProgress: decoded[2].progress }
  }, fixtures)
  expect(report.identical).toBe(true)
  expect(report.ordinaryRatio).toBeCloseTo(2, 5)
  expect(report.negative[0].scale).toBe(report.negative[1].scale)
  for (const image of report.negative) {
    expect(image).toMatchObject({ width: 192, height: 320, bits: 16, profile: null, kelvin: null })
    expect(image.codes).toBeGreaterThan(256)
    expect(image.progress).toContain('Decoding RAW negative without highlight reconstruction')
    expect(image.progress).not.toContain('Loading camera spectral profiles')
  }
  expect(report.ordinaryProgress).toContain('Loading camera spectral profiles')
})

test('RAW negative mode leaves unequal clipped channels unreconstructed', async ({ page }) => {
  await page.goto('/')
  const samples = await page.evaluate(async bytes => {
    const { decodeRaw } = await import('/src/raw-import.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const samples = []
    for (const negative of [false, true]) {
      const image = await decodeRaw(new File([new Uint8Array(bytes)], 'clipped.dng'), { negative })
      const source = rawSource(image, defaultEdit())
      samples.push(Array.from(source.read(100, 100, 1, 1)).slice(0, 3))
    }
    return samples
  }, Array.from(makeDNG({ asShotNeutral: [0.5, 1, 0.625], patches: [[1.5, 1.5, 1.5]] })))
  const span = rgb => Math.max(...rgb) - Math.min(...rgb)
  expect(span(samples[0])).toBeLessThan(0.01)
  expect(span(samples[1])).toBeGreaterThan(0.1)
})
