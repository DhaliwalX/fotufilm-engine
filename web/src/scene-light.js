import { assetUrl } from './engine.js'

// One worker retains the stock-independent reconstruction. Completed exposure
// tables are shared across output media and reused until the photo or film changes.
let worker,
  serial = 0
const pending = new Map(),
  cache = new Map()
export function loadSceneExposure(stock, kelvin, onProgress = () => {}) {
  if (!Number.isFinite(kelvin) || kelvin <= 0) return Promise.resolve(null)
  const key = `${stock}:${Math.fround(kelvin)}`
  if (cache.has(key)) {
    const entry = cache.get(key)
    cache.delete(key)
    cache.set(key, entry)
    if (!entry.done) {
      entry.listeners.add(onProgress)
      if (entry.status) onProgress(entry.status)
    }
    return entry.promise
  }
  if (!worker) {
    worker = new Worker(new URL('./scene-light-worker.js', import.meta.url), { type: 'module' })
    worker.onmessage = ({ data }) => {
      const request = pending.get(data.id)
      if (!request) return
      if (data.status) {
        request.onProgress(data.status)
        return
      }
      pending.delete(data.id)
      if (data.error) request.reject(new Error(data.error))
      else request.resolve(data.exposure)
    }
    worker.onerror = () => {
      for (const request of pending.values())
        request.reject(new Error('Scene-light worker failed.'))
      pending.clear()
      cache.clear()
      worker.terminate()
      worker = null
    }
  }
  const entry = { listeners: new Set([onProgress]), done: false, status: null }
  entry.promise = new Promise((resolve, reject) => {
    const id = ++serial
    pending.set(id, {
      resolve,
      reject,
      onProgress: (status) => {
        entry.status = status
        for (const listener of entry.listeners) listener(status)
      },
    })
    worker.postMessage({ id, stock, kelvin: Math.fround(kelvin), base: assetUrl('packs/scene/') })
  })
    .catch((error) => {
      cache.delete(key)
      throw error
    })
    .finally(() => {
      entry.done = true
      entry.listeners.clear()
    })
  cache.set(key, entry)
  if (cache.size > 8) cache.delete(cache.keys().next().value)
  return entry.promise
}
