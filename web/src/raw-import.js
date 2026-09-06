import { assetUrl, developNormal } from './engine.js'
import { defaultEdit } from './editor-state.js'
import { canvasBlob } from './geometry.js'
import { rawSource } from './raw-source.js'

export const RAW_EXTENSIONS = [
  'dng',
  'cr2',
  'cr3',
  'crw',
  'nef',
  'nrw',
  'arw',
  'srf',
  'sr2',
  'raf',
  'orf',
  'ori',
  'rw2',
  'raw',
  'rwl',
  'pef',
  'ptx',
  'srw',
  '3fr',
  'fff',
  'iiq',
  'kdc',
  'dcr',
  'mrw',
  'mos',
  'erf',
  'mef',
  'mdc',
  'x3f',
]
export const IMAGE_ACCEPT = ['image/*', ...RAW_EXTENSIONS.map((ext) => `.${ext}`)].join(',')
export const isRawFile = (file) =>
  RAW_EXTENSIONS.includes(file.name.split('.').at(-1).toLowerCase()) ||
  /(?:raw|dng|cr2|cr3|nef|arw|raf)/i.test(file.type)

// Treat a decoded RAW like an image resource. Pixel buffers must stay opaque to
// React/devtools state inspection, which can otherwise enumerate millions of samples.
class RawImage {
  #pixels
  constructor(width, height, data, colors) {
    this.naturalWidth = width
    this.naturalHeight = height
    this.#pixels = { data, colors }
  }
  get raw() {
    return this.#pixels
  }
}

export function decodeRaw(file, { signal, onProgress = () => {} } = {}) {
  return new Promise((resolve, reject) => {
    if (file.size > 512 * 1024 * 1024) {
      reject(new Error('RAW files above 512 MB are not supported.'))
      return
    }
    if (signal?.aborted) {
      reject(new DOMException('Import cancelled.', 'AbortError'))
      return
    }
    const worker = new Worker(new URL('./raw-worker.js', import.meta.url), {
      type: 'module',
    })
    let settled = false
    const finish = (error, result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', abort)
      worker.terminate()
      if (error) reject(error)
      else resolve(result)
    }
    const abort = () => finish(new DOMException('Import cancelled.', 'AbortError'))
    const timer = setTimeout(
      () => finish(new Error('RAW decoding timed out. Try a smaller file.')),
      180000,
    )
    signal?.addEventListener('abort', abort, { once: true })
    worker.onerror = (event) => {
      event.preventDefault()
      finish(new Error('The RAW decoder could not run. Reload the editor and try again.'))
    }
    worker.onmessage = ({ data }) => {
      if (data.status) {
        onProgress(data.status)
        return
      }
      if (data.error) {
        finish(new Error(`Could not decode RAW: ${data.error}`))
        return
      }
      if (
        !(data.pixels instanceof Uint16Array) ||
        ![1, 3].includes(data.colors) ||
        !Number.isInteger(data.width) ||
        !Number.isInteger(data.height) ||
        data.width < 1 ||
        data.height < 1 ||
        data.width * data.height > 120000000 ||
        data.pixels.length !== data.width * data.height * data.colors
      ) {
        finish(new Error('The RAW decoder returned an invalid image.'))
        return
      }
      finish(null, new RawImage(data.width, data.height, data.pixels, data.colors))
    }
    onProgress('Opening RAW')
    file
      .arrayBuffer()
      .then((bytes) => {
        if (!settled && !signal?.aborted)
          worker.postMessage({ bytes, decoderURL: assetUrl('raw/decoder.mjs') }, [bytes])
      })
      .catch((error) => finish(error))
  })
}

export async function importRaw(file, options) {
  const image = await decodeRaw(file, options)
  const source = rawSource(image, defaultEdit(), 1600)
  const { pixels } = await developNormal(source, defaultEdit().params)
  if (options?.signal?.aborted) throw new DOMException('Import cancelled.', 'AbortError')
  const canvas = document.createElement('canvas')
  canvas.width = source.width
  canvas.height = source.height
  canvas.getContext('2d').putImageData(new ImageData(pixels, source.width, source.height), 0, 0)
  const url = URL.createObjectURL(await canvasBlob(canvas))
  image.src = url
  return { image, url }
}
