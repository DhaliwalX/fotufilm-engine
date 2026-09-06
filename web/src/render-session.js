import {
  assetUrl,
  createDeveloper,
  developNormal,
  imageSource,
  loadPack,
  loadStages,
} from './engine.js'
import { canvasBlob, cropImage, orientImage } from './geometry.js'

export async function loadStockIndex() {
  const response = await fetch(assetUrl('packs/index.json'))
  if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) {
    throw new Error('The film library could not be loaded.')
  }
  const index = await response.json()
  if (
    !Array.isArray(index) ||
    !index.length ||
    index.some((s) => !s.id || !s.name || !/^[a-z0-9_-]+$/i.test(s.id))
  )
    throw new Error('Invalid film library.')
  return index
}

// WASM instances share a heap. Serialize stock changes, renders, exports and disposal.
export class RenderSession {
  constructor() {
    this.pending = []
    this.running = false
    this.packs = new Map()
    this.developer = null
    this.closed = false
  }
  enqueue(work, background = false) {
    return new Promise((resolve, reject) => {
      this.pending.push({ work, background, resolve, reject })
      this.drain()
    })
  }
  async drain() {
    if (this.running) return
    this.running = true
    while (this.pending.length) {
      const firstForeground = this.pending.findIndex((item) => !item.background)
      const [item] = this.pending.splice(Math.max(0, firstForeground), 1)
      try {
        item.resolve(await item.work())
      } catch (error) {
        item.reject(error)
      }
    }
    this.running = false
  }
  async pack(id) {
    if (this.packs.has(id)) {
      const value = this.packs.get(id)
      this.packs.delete(id)
      this.packs.set(id, value)
      return value
    }
    const pack = await loadPack(assetUrl(`packs/${id}.pack`))
    const entry = { pack, stages: null }
    this.packs.set(id, entry)
    if (this.packs.size > 4) this.packs.delete(this.packs.keys().next().value)
    return entry
  }
  render({
    image,
    edit,
    stock,
    maxEdge = 1600,
    stage = null,
    difference = false,
    cropMode = false,
    background = false,
    stale = () => false,
    onProgress = () => {},
  }) {
    return this.enqueue(async () => {
      if (this.closed || stale()) return null
      onProgress('Loading film')
      const entry = edit.stock === null ? null : await this.pack(stock)
      if (this.closed || stale()) return null
      if (entry && !this.developer) this.developer = await createDeveloper(entry.pack)
      const developer = this.developer
      if (entry && stage !== null) {
        entry.stages ??= await loadStages(assetUrl(`packs/${stock}.stages`), entry.pack)
      }
      if (stale()) return null
      const oriented = orientImage(image, edit, maxEdge)
      const sourceCanvas = cropMode ? oriented : await cropImage(oriented, edit)
      const source = imageSource(sourceCanvas)
      const controls = {
        ...edit.params,
        gradeSpace: edit.gradeSpace,
        seed: edit.seed,
        localTone: edit.localTone,
      }
      const selected = edit.stock === null ? null : stage
      const pack = entry ? (selected === null ? entry.pack : entry.stages[selected]) : null
      if (entry && !pack) throw new Error('This pipeline stage is unavailable.')
      onProgress('Developing')
      if (pack) developer.usePack(pack)
      let { pixels, elapsed } = pack
        ? await developer.develop(source, controls)
        : await developNormal(source, controls)
      let delta = null
      if (difference && selected > 0) {
        developer.usePack(entry.stages[selected - 1])
        const before = await developer.develop(source, controls)
        let peak = 0
        for (let i = 0; i < pixels.length; i++)
          if (i % 4 !== 3) peak = Math.max(peak, Math.abs(pixels[i] - before.pixels[i]))
        const gain = peak < 0.5 ? 1 : Math.min(128, 127 / peak)
        pixels = pixels.map((v, i) => (i % 4 === 3 ? 255 : 128 + (v - before.pixels[i]) * gain))
        delta = { peak, gain }
      }
      if (stale()) return null
      const canvas = document.createElement('canvas')
      canvas.width = source.width
      canvas.height = source.height
      canvas.getContext('2d').putImageData(new ImageData(pixels, source.width, source.height), 0, 0)
      const blob = await canvasBlob(canvas)
      const original = await canvasBlob(sourceCanvas)
      return {
        canvas,
        blob,
        original,
        elapsed,
        delta,
        backend: pack ? developer.backend : 'normal',
        width: canvas.width,
        height: canvas.height,
      }
    }, background)
  }
  stages(stock) {
    return this.enqueue(async () => {
      const entry = await this.pack(stock)
      entry.stages ??= await loadStages(assetUrl(`packs/${stock}.stages`), entry.pack)
      return entry.stages.map((s) => ({ id: s.id, label: s.label }))
    })
  }
  dispose() {
    this.closed = true
    return this.enqueue(() => {
      this.developer?.dispose()
      this.developer = null
      this.packs.clear()
    })
  }
}
