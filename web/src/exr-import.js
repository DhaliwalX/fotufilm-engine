import { LinearImage } from './linear-image.js'
import { decodeImageWorker } from './image-worker.js'
import { developNormal } from './engine.js'
import { defaultEdit } from './editor-state.js'
import { rawSource } from './raw-source.js'
import { canvasBlob } from './geometry.js'

export const isEXRFile = (file) => /\.exr$/i.test(file.name)

export async function decodeEXRFile(file, options = {}) {
  options.onProgress?.('Reading linear EXR')
  const result = await decodeImageWorker(file,
    () => new Worker(new URL('./exr-worker.js', import.meta.url), { type: 'module' }), {
    ...options, label: 'EXR',
  })
  return new LinearImage(result)
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
