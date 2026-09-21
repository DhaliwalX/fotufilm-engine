import { assetUrl } from './engine.js'
import { LinearImage } from './linear-image.js'
import { decodeImageWorker } from './image-worker.js'
import { attachLinearPreview } from './linear-preview.js'
import { readPhotoMetadata } from './photo-metadata.js'

export function isDeepPNG(header) {
  return (
    header.length >= 25 &&
    [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => header[i] === v) &&
    header[12] === 73 &&
    header[13] === 72 &&
    header[14] === 68 &&
    header[15] === 82 &&
    header[24] === 16
  )
}
export async function importDeepPNG(file, options = {}) {
  const metadata = await readPhotoMetadata(file, options)
  const decoded = await decodeImageWorker(
    file,
    () =>
      new Worker(new URL('./png-worker.js', import.meta.url), {
        type: 'module',
      }),
    {
      ...options,
      label: '16-bit PNG',
      message: {
        decoderURL: assetUrl('png/decoder.mjs'),
        orientation: metadata.orientation || 1,
      },
    },
  )
  if (!decoded) throw new Error('This file is not a 16-bit PNG.')
  const image = new LinearImage(decoded)
  image.lensMetadata = metadata
  image.deep = { format: 'PNG', bitDepth: 16 }
  return attachLinearPreview(image, options)
}
