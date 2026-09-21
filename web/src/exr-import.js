import { attachLinearPreview } from './linear-preview.js'
import { LinearImage } from './linear-image.js'
import { decodeImageWorker } from './image-worker.js'

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
  return attachLinearPreview(image, options)
}
