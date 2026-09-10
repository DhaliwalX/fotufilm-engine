import { loadMediumBytes } from './output-media.js'
import { loadSceneExposure } from './scene-light.js'
import { rawSource } from './raw-source.js'
import { defaultEdit } from './editor-state.js'
import {
  assetUrl,
  createDeveloper,
  createCpuDeveloper,
  createNormalDeveloper,
  linearSource,
  developNormal,
  imageSource,
  loadPack,
  parsePack,
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
  const mediaResponse = await fetch(assetUrl('packs/media.json'))
  if (!mediaResponse.ok)
    throw new Error('Output media could not be loaded. Rebuild the browser packs.')
  const media = await mediaResponse.json()
  return index.map((stock) => {
    const entry = media.find((item) => item.id === stock.id)
    if (!entry || !Array.isArray(entry.choices) || !entry.choices.length)
      throw new Error('Invalid output-medium catalog.')
    return { ...stock, media: entry.choices, defaultMedium: entry.default }
  })
}

// WASM instances share a heap. Serialize stock changes, renders, exports and disposal.
export class RenderSession {
  constructor() {
    this.pending = []
    this.running = false
    this.activeWork = null
    this.packs = new Map()
    this.developer = null
    this.normal = null
    this.thumbnail = null
    this.sources = []
    this.scenePacks = new WeakMap()
    this.closed = false
  }
  notifyWaiting() {
    if (!this.activeWork) return
    const { label, stage } = this.activeWork
    for (const item of this.pending)
      item.details.onWait?.(`Waiting for ${label}${stage ? ` · ${stage}` : ''}`)
  }
  enqueue(work, background = false, details = { label: 'engine work' }) {
    return new Promise((resolve, reject) => {
      this.pending.push({ work, background, details, resolve, reject })
      this.notifyWaiting()
      this.drain()
    })
  }
  async drain() {
    if (this.running) return
    this.running = true
    while (this.pending.length) {
      const firstForeground = this.pending.findIndex((item) => !item.background)
      const [item] = this.pending.splice(Math.max(0, firstForeground), 1)
      this.activeWork = item.details
      this.notifyWaiting()
      try {
        item.resolve(await item.work())
      } catch (error) {
        item.reject(error)
      }
    }
    this.activeWork = null
    this.running = false
  }
  async pack(id, medium = null, halationModel = 'legacy') {
    const key = `${id}:${medium || 'default'}:${halationModel}`
    if (this.packs.has(key)) {
      const value = this.packs.get(key)
      this.packs.delete(key)
      this.packs.set(key, value)
      return value
    }
    let pack,
      stagesUrl = null
    if (halationModel === 'layered') {
      if (medium) throw new Error('Layered Transport uses the film’s default output medium.')
      pack = await loadPack(assetUrl(`packs/${id}.layered.pack`))
    } else if (medium) {
      this.catalog ??= loadStockIndex().catch((error) => {
        this.catalog = null
        throw error
      })
      const stock = (await this.catalog).find((item) => item.id === id)
      const choice = stock?.media.find((item) => item.id === medium)
      if (!choice) throw new Error('This output medium is unavailable for the selected film.')
      const base = await this.pack(id)
      pack = choice.pack
        ? parsePack(await loadMediumBytes(base.pack.bytes, assetUrl(`packs/${choice.pack}`)))
        : base.pack
      stagesUrl = choice.stages ? assetUrl(`packs/${choice.stages}`) : null
    } else pack = await loadPack(assetUrl(`packs/${id}.pack`))
    const entry = { pack, stages: null, stagesUrl }
    this.packs.set(key, entry)
    if (this.packs.size > 4) this.packs.delete(this.packs.keys().next().value)
    return entry
  }
  async renderer(pack, background = false, onProgress = () => {}) {
    const name = background ? 'thumbnailReady' : pack?.transport ? 'transportReady' : pack ? 'filmReady' : 'normalReady'
    // A thumbnail must not hold foreground work behind GPU shader compilation.
    this[name] ??= (
      background ? createCpuDeveloper(pack) : pack ? createDeveloper(pack, onProgress) : createNormalDeveloper()
    )
      .then((developer) => {
        if (this.closed) {
          developer?.dispose()
          return null
        }
        if (background) this.thumbnail = developer
        else if (pack?.transport) this.transport = developer
        else if (pack) this.developer = developer
        else this.normal = developer
        return developer
      })
      .catch((error) => {
        this[name] = null
        throw error
      })
    return this[name]
  }
  async source(image, edit, maxEdge, cropMode) {
    const key = JSON.stringify([
      maxEdge,
      cropMode,
      edit.rotation,
      edit.flip,
      cropMode ? null : edit.crop,
      cropMode ? 0 : edit.straighten,
    ])
    const cached = this.sources.find((item) => item.image === image && item.key === key)
    if (cached) return cached
    const floating = image.raw || image.linear
    const oriented = floating ? null : orientImage(image, edit, maxEdge)
    const canvas = floating ? null : cropMode ? oriented : await cropImage(oriented, edit)
    const source = linearSource(
      floating ? rawSource(image, edit, maxEdge, cropMode) : imageSource(canvas),
    )
    const entry = { image, key, canvas, source, original: null }
    if (maxEdge <= 2400) {
      this.sources.unshift(entry)
      this.sources.length = Math.min(3, this.sources.length)
    }
    return entry
  }
  async capturePack(pack, stock, kelvin, report) {
    if (!pack || !Number.isFinite(kelvin) || kelvin <= 0) return pack
    const key = pack.id === '01-bypassed' ? stock + '@bypassed' : stock
    const exposure = await loadSceneExposure(key, kelvin, report)
    const cached = this.scenePacks.get(pack)
    if (cached?.exposure === exposure) return cached
    const corrected = { ...pack, exposure }
    this.scenePacks.set(pack, corrected)
    return corrected
  }
  async render({
    image,
    edit,
    stock,
    maxEdge = 1600,
    stage = null,
    difference = false,
    cropMode = false,
    background = false,
    comparison = !background,
    purpose = 'preview',
    stale = () => false,
    onProgress = () => {},
  }) {
    if (this.closed || stale()) return null
    if (edit.halationModel === 'layered' && image.raw?.sceneKelvin)
      throw new Error('Layered Transport is unavailable for RAW photos with a detected capture light. Choose Legacy.')
    const work = { label: background ? 'film thumbnail' : purpose }
    const report = (text) => {
      if (this.activeWork === work) {
        work.stage = text
        this.notifyWaiting()
      }
      if (!this.closed && !stale()) onProgress(text)
    }
    if (edit.stock !== null && !this.packs.has(`${stock}:${edit.medium || 'default'}:${edit.halationModel || 'legacy'}`))
      report(edit.medium ? 'Loading film and output-medium profile' : 'Loading film profile')
    const entry = edit.stock === null ? null : await this.pack(stock, edit.medium, edit.halationModel)
    if (this.closed || stale()) return null
    if (!entry && !this.normalReady) report('Loading light and color engine')
    const developer = await this.renderer(entry?.pack, background && !!entry, report)
    work.onWait = report
    return this.enqueue(async () => {
      if (this.closed || stale()) return null
      const started = performance.now()
      if (entry?.pack.transport && stage !== null) throw new Error('Pipeline inspection is available with Legacy.')
      if (entry && stage !== null) {
        report('Loading pipeline inspection stages')
        entry.stages ??= await loadStages(
          assetUrl(`packs/${stock}.stages`),
          entry.pack,
          entry.stagesUrl,
        )
      }
      if (stale()) return null
      report(cropMode ? 'Preparing crop canvas' : 'Preparing crop and image pixels')
      const prepared = await this.source(image, edit, maxEdge, cropMode)
      const { source, canvas: sourceCanvas } = prepared
      const rendering = (text) => report(`${text} · ${source.width}×${source.height} ${purpose}`)
      const controls = {
        ...edit.params,
        gradeSpace: edit.gradeSpace,
        seed: edit.seed,
        localTone: edit.localTone,
      }
      const selected = edit.stock === null ? null : stage
      const pack = await this.capturePack(
        entry ? (selected === null ? entry.pack : entry.stages[selected]) : null,
        stock, image.raw?.sceneKelvin, report,
      )
      if (entry && !pack) throw new Error('This pipeline stage is unavailable.')
      if (pack) developer.usePack(pack)
      let { pixels, elapsed } = developer
        ? await developer.develop(source, controls, rendering)
        : await developNormal(source, controls, rendering)
      let delta = null
      if (difference && selected > 0) {
        report('Rendering previous stage for comparison')
        developer.usePack(await this.capturePack(entry.stages[selected - 1], stock, image.raw?.sceneKelvin, report))
        const before = await developer.develop(source, controls)
        let peak = 0
        for (let i = 0; i < pixels.length; i++)
          if (i % 4 !== 3) peak = Math.max(peak, Math.abs(pixels[i] - before.pixels[i]))
        const gain = peak < 0.5 ? 1 : Math.min(128, 127 / peak)
        pixels = pixels.map((v, i) => (i % 4 === 3 ? 255 : 128 + (v - before.pixels[i]) * gain))
        delta = { peak, gain }
      }
      if (stale()) return null
      report(`Encoding ${purpose} image`)
      const canvas = document.createElement('canvas')
      canvas.width = source.width
      canvas.height = source.height
      canvas.getContext('2d').putImageData(new ImageData(pixels, source.width, source.height), 0, 0)
      const blob = await canvasBlob(canvas)
      let original = prepared.original
      if (comparison && !original) report('Preparing original for comparison')
      if (comparison && !original && sourceCanvas) original = await canvasBlob(sourceCanvas)
      else if (comparison && !original) {
        const baseline = await developNormal(source, defaultEdit().params)
        const comparison = document.createElement('canvas')
        comparison.width = source.width
        comparison.height = source.height
        comparison
          .getContext('2d')
          .putImageData(new ImageData(baseline.pixels, source.width, source.height), 0, 0)
        original = await canvasBlob(comparison)
      }
      prepared.original = original
      return {
        canvas,
        blob,
        original,
        elapsed,
        renderMilliseconds: performance.now() - started,
        delta,
        backend: pack ? developer.backend : 'normal',
        width: canvas.width,
        height: canvas.height,
      }
    }, background, work)
  }
  stages(stock, medium = null, halationModel = 'legacy') {
    if (halationModel === 'layered') return Promise.resolve([])
    return this.enqueue(async () => {
      const entry = await this.pack(stock, medium)
      entry.stages ??= await loadStages(
        assetUrl(`packs/${stock}.stages`),
        entry.pack,
        entry.stagesUrl,
      )
      return entry.stages.map((s) => ({ id: s.id, label: s.label }))
    }, false, { label: 'pipeline inspection profiles' })
  }
  dispose() {
    this.closed = true
    return this.enqueue(() => {
      this.developer?.dispose()
      this.transport?.dispose()
      this.normal?.dispose()
      this.thumbnail?.dispose()
      this.sources = []
      this.normal = null
      this.thumbnail = null
      this.developer = null
      this.transport = null
      this.packs.clear()
    })
  }
}
