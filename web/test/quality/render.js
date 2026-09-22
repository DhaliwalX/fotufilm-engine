import { pixelSource } from '../../src/engine.js'

export function syntheticScene(width, height) {
  const data = new Float32Array(width * height * 4)
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4
      const highlight =
        Math.abs(x - width * 0.6) < width * 0.08 &&
        Math.abs(y - height * 0.4) < height * 0.1
      data[i] = highlight ? 4 : 0.002 + (1.8 * x) / width
      data[i + 1] = highlight ? 3 : 0.003 + (0.9 * y) / height
      data[i + 2] = highlight ? 2 : 0.001 + 0.7 * (1 - x / width)
      data[i + 3] = 1
    }
  return pixelSource({ width, height, data })
}

export async function render(developer, source, controls, colorSpace) {
  developer.tileBudget = Infinity
  const start = performance.now()
  const result = await developer.develop(
    source,
    controls,
    () => {},
    () => false,
    { colorSpace },
  )
  const totalMilliseconds = performance.now() - start
  const { width, height } = source
  const region = { x: 0, y: 0, width, height }
  // Inspect linear output through the diagnostic entry point, independently of
  // the production GPU display encoder.
  const status = await developer.run(region)
  if (status !== 0) throw new Error(`Raw render returned ${status}`)
  const raw = developer.regionOutput(region)
  const offsets = developer.outputOffsets(region)
  const linear = new Float32Array(width * height * 3)
  for (let p = 0; p < width * height; p++)
    for (let c = 0; c < 3; c++) {
      linear[p * 3 + c] = raw[p * developer.outputStride + offsets[c]]
    }
  const deepResult = await developer.develop(
    source,
    controls,
    () => {},
    () => false,
    { bitDepth: 16, colorSpace },
  )
  const deep = deepResult.pixels
  return {
    linear,
    byte: result.pixels,
    deep,
    kernelMilliseconds: result.elapsed,
    totalMilliseconds,
  }
}
