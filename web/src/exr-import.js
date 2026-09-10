import { developNormal } from './engine.js'
import { defaultEdit } from './editor-state.js'
import { rawSource } from './raw-source.js'
import { canvasBlob } from './geometry.js'

export const isEXRFile = (file) => /\.exr$/i.test(file.name)

class LinearImage {
  #pixels
  constructor({ pixels, width, height }) {
    this.naturalWidth = width
    this.naturalHeight = height
    this.#pixels = { data: pixels, colors: 4 }
  }
  get linear() {
    return this.#pixels
  }
}

export function decodeEXRFile(file, { signal, onProgress = () => {} } = {}) {
  return new Promise((resolve, reject) => {
    if (file.size > 512 * 1024 * 1024)
      return reject(new Error('EXR files above 512 MB are not supported.'))
    if (signal?.aborted) return reject(new DOMException('Import cancelled.', 'AbortError'))
    const worker = new Worker(new URL('./exr-worker.js', import.meta.url), { type: 'module' })
    let settled = false
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', abort)
      worker.terminate()
      if (error) reject(error)
      else resolve(new LinearImage(value))
    }
    const abort = () => finish(new DOMException('Import cancelled.', 'AbortError'))
    const timer = setTimeout(() => finish(new Error('EXR decoding timed out.')), 180000)
    signal?.addEventListener('abort', abort, { once: true })
    worker.onerror = () => finish(new Error('The EXR decoder could not run.'))
    worker.onmessage = ({ data }) =>
      data.error ? finish(new Error(data.error)) : finish(null, data)
    onProgress('Reading linear EXR')
    file
      .arrayBuffer()
      .then((bytes) => {
        if (!settled) worker.postMessage({ bytes }, [bytes])
      })
      .catch((error) => finish(error))
  })
}

export async function importEXR(file, options) {
  const image = await decodeEXRFile(file, options)
  options?.onProgress?.('Preparing EXR display preview')
  const source = rawSource(image, defaultEdit(), 1600)
  const { pixels } = await developNormal(source, defaultEdit().params, options?.onProgress)
  if (options?.signal?.aborted) throw new DOMException('Import cancelled.', 'AbortError')
  const canvas = document.createElement('canvas')
  canvas.width = source.width
  canvas.height = source.height
  canvas.getContext('2d').putImageData(new ImageData(pixels, source.width, source.height), 0, 0)
  const url = URL.createObjectURL(await canvasBlob(canvas))
  image.src = url
  return { image, url }
}
