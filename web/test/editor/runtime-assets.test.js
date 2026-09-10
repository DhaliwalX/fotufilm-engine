import test from 'node:test'
import assert from 'node:assert/strict'
import { runtimeAssetUrl, relatedAssetUrl, createRuntimeLoader, supportsWebgpuRuntime } from '../../src/runtime-assets.js'

test('runtime files and relative worker assets keep the same release revision', () => {
  const module = runtimeAssetUrl('fotufilm.mjs', '/demo/', 'https://fotufilm.com/demo/', 'new-build')
  assert.equal(module, 'https://fotufilm.com/demo/fotufilm.mjs?v=new-build')
  assert.equal(relatedAssetUrl('fotufilm.wasm', module), 'https://fotufilm.com/demo/fotufilm.wasm?v=new-build')
  const raw = runtimeAssetUrl('raw/decoder.mjs', '/demo/', 'https://fotufilm.com/', 'new-build')
  assert.equal(relatedAssetUrl('decoder.wasm', raw), 'https://fotufilm.com/demo/raw/decoder.wasm?v=new-build')
  assert.equal(relatedAssetUrl('camera-profiles.json', raw), 'https://fotufilm.com/demo/raw/camera-profiles.json?v=new-build')
  const scene = runtimeAssetUrl('packs/scene/', '/demo/', 'https://fotufilm.com/', 'new-build')
  assert.equal(relatedAssetUrl('geometry.spectra', scene), 'https://fotufilm.com/demo/packs/scene/geometry.spectra?v=new-build')
})

test('module retries discard failed loads and aborted instances, and version the binary', async () => {
  let calls = 0, options
  const loader = createRuntimeLoader(() => 'https://fotufilm.com/demo/fotufilm.mjs?v=fresh', async () => ({
    default: async value => {
      options = value
      if (++calls === 1) throw new Error('interrupted download')
      return { instance: calls }
    },
  }))
  await assert.rejects(loader.load('simd'), /interrupted download/)
  const module = await loader.load('simd')
  assert.equal(await loader.load('simd'), module)
  assert.equal(options.locateFile('fotufilm.wasm'), 'https://fotufilm.com/demo/fotufilm.wasm?v=fresh')
  options.onAbort()
  assert.equal(loader.wasAborted(module), true)
  assert.notEqual(await loader.load('simd'), module)
  assert.equal(calls, 3)
})

test('WebGPU requires JSPI as well as an adapter API', () => {
  assert.equal(supportsWebgpuRuntime({}, {}), false)
  assert.equal(supportsWebgpuRuntime({}, { Suspending() {} }), false)
  assert.equal(supportsWebgpuRuntime(null, { Suspending() {}, promising() {} }), false)
  assert.equal(supportsWebgpuRuntime({}, { Suspending() {}, promising() {} }), true)
})
