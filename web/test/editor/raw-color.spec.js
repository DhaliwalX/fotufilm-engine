import { test, expect } from '@playwright/test'
import { makeDNG } from './raw-fixture.js'

const patches = [
  [0.18, 0.18, 0.18],
  [0.6, 0.1, 0.05],
  [0.05, 0.6, 0.1],
  [0.05, 0.1, 0.6],
  [0.9, 0.9, 0.9],
  [1.5, 1.5, 1.5],
  [3, 3, 3],
  [0.02, 0.02, 0.02],
]

test('RAW white balance preserves scene exposure, color patches and neutral clipped highlights', async ({
  page,
}) => {
  await page.goto('/')
  const report = await page.evaluate(
    async (bytes) => {
      const { decodeRaw } = await import('/src/raw-import.js')
      const { rawSource } = await import('/src/raw-source.js')
      const { defaultEdit } = await import('/src/editor-state.js')
      const image = await decodeRaw(new File([new Uint8Array(bytes)], 'highlights.dng'))
      const source = rawSource(image, defaultEdit())
      return {
        scale: image.raw.sceneScale,
        samples: Array.from({ length: 8 }, (_, i) =>
          Array.from(
            source.read(
              Math.floor(((i + 0.5) * source.width) / 8),
              Math.floor(source.height / 2),
              1,
              1,
            ),
          ).slice(0, 3),
        ),
      }
    },
    Array.from(makeDNG({ width: 640, asShotNeutral: [0.5, 1, 0.625], patches })),
  )
  console.log('RAW scene color patches:', report)
  expect(report.scale).toBeCloseTo(2, 4)
  const to2020 = [
    [0.6274039, 0.329283, 0.0433131],
    [0.0690973, 0.9195404, 0.0113623],
    [0.0163914, 0.0880133, 0.8955953],
  ]
  // These sensor patches are below clipping; check color, not just CPU/GPU agreement.
  for (const i of [0, 1, 2, 3, 4, 7]) {
    const expected = to2020.map((row) => row.reduce((sum, n, c) => sum + n * patches[i][c], 0))
    for (let c = 0; c < 3; c++)
      expect(Math.abs(report.samples[i][c] - expected[c])).toBeLessThan(0.002)
  }
  // Unequally clipped camera channels must not turn a white patch magenta.
  // Preserve recovered luminance above 1 so exposure reduction can reveal it.
  for (const i of [5, 6]) {
    const rgb = report.samples[i]
    expect(Math.max(...rgb) - Math.min(...rgb)).toBeLessThan(0.01)
    expect(Math.min(...rgb)).toBeGreaterThan(1)
  }
})

test('RAW exposure follows the green reference and explicit DNG baseline under different white balances', async ({
  page,
}) => {
  await page.goto('/')
  const fixtures = [
    [0.5, 1, 0.625],
    [0.4, 1, 2],
  ].map((asShotNeutral) =>
    Array.from(
      makeDNG({
        asShotNeutral,
        baselineExposure: 0.5,
        patches: [[0.18, 0.18, 0.18]],
      }),
    ),
  )
  const samples = await page.evaluate(async (fixtures) => {
    const { decodeRaw } = await import('/src/raw-import.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const samples = []
    for (const bytes of fixtures) {
      const image = await decodeRaw(new File([new Uint8Array(bytes)], 'neutral.dng'))
      const source = rawSource(image, defaultEdit())
      samples.push(Array.from(source.read(100, 100, 1, 1)).slice(0, 3))
    }
    return samples
  }, fixtures)
  for (const rgb of samples)
    for (const channel of rgb) expect(Math.abs(channel - 0.18 * Math.sqrt(2))).toBeLessThan(0.002)
})
