import {
  assetUrl,
  loadPack,
  normalPack,
  SimdDeveloper,
  WebgpuDeveloper,
} from '../../src/engine.js'
import { relatedAssetUrl } from '../../src/runtime-assets.js'
import { acceptsImage, differences } from './metrics.js'
import { render, syntheticScene } from './render.js'

const output = document.querySelector('#report')
const query = new URLSearchParams(location.search)
try {
  if (!navigator.gpu)
    throw new Error(
      'An actual WebGPU device is required; CPU fallback is not coverage',
    )
  const width = Number(query.get('width') || 384),
    height = Number(query.get('height') || 256)
  if (![width, height].every((n) => Number.isInteger(n) && n > 0 && n <= 4096))
    throw new Error('Invalid dimensions')
  const modules = []
  for (const name of [
    'fotufilm.mjs',
    query.get('gpu') || 'fotufilm-webgpu.mjs',
  ]) {
    const url = assetUrl(name),
      { default: factory } = await import(/* @vite-ignore */ url)
    modules.push(
      await factory({ locateFile: (name) => relatedAssetUrl(name, url) }),
    )
  }
  const index = await (await fetch(assetUrl('packs/index.json'))).json()
  const stocks =
    query.get('stocks') === 'all'
      ? ['normal', ...index.map((s) => s.id)]
      : (query.get('stocks') || 'normal,gold200,trix400,velvia50').split(',')
  const source = syntheticScene(width, height),
    results = []
  for (const stock of stocks) {
    const pack =
      stock === 'normal'
        ? normalPack()
        : await loadPack(assetUrl(`packs/${stock}.pack`))
    const developers = [
      new SimdDeveloper(modules[0], pack),
      new WebgpuDeveloper(modules[1], pack),
    ]
    try {
      for (const ev of [-2, 0, 2])
        for (const grain of [0, 1]) {
          const colorSpace = ev === 2 ? 'display-p3' : 'srgb'
          document.title = `Quality: ${stock} EV ${ev} grain ${grain}`
          const frames = []
          for (const developer of developers)
            frames.push(
              await render(developer, source, { ev, grain }, colorSpace),
            )
          const row = { stock, ev, grain, colorSpace }
          for (const key of ['linear', 'byte', 'deep'])
            row[key] = differences(frames[0][key], frames[1][key])
          row.pass = acceptsImage(row)
          row.cpuMilliseconds = frames[0].kernelMilliseconds
          row.gpuMilliseconds = frames[1].kernelMilliseconds
          results.push(row)
          output.textContent = JSON.stringify(
            { width, height, results },
            null,
            2,
          )
        }
    } finally {
      developers.forEach((d) => d.dispose())
    }
  }
  document.title = `WebGPU quality — ${results.every((r) => r.pass) ? 'PASS' : 'FAIL'}`
} catch (error) {
  output.textContent = JSON.stringify({ error: error.stack }, null, 2)
  document.title = 'WebGPU quality — ERROR'
}
