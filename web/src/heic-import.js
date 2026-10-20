import { hevcAssets } from './hevc-assets.js'
import { LinearImage } from './linear-image.js'
import { decodeImageWorker } from './image-worker.js'
import { attachLinearPreview } from './linear-preview.js'
import { readPhotoMetadata } from './photo-metadata.js'

// HEIC through the software HEVC decoder, in every browser alike: most cannot decode it, and
// the one that can would hand back display pixels instead of the photo's own samples.
function decodeHEIC(file, options, thumbnail = 0) {
  return decodeImageWorker(
    file,
    () => new Worker(new URL('./heic-worker.js', import.meta.url)),
    { ...options, label: 'HEIC', message: { ...hevcAssets(), thumbnail } },
  )
}
export async function importHEIC(file, options = {}) {
  const decoded = await decodeHEIC(file, options)
  const image = new LinearImage(decoded)
  image.deep = { format: 'HEIC', bitDepth: decoded.bitDepth }
  image.lensMetadata = await readPhotoMetadata(file, options)
  return attachLinearPreview(image, options)
}
// The file's own thumbnail where it has one: `{pixels, width, height}`, sRGB RGBA bytes.
export const heicThumbnail = (file, maxEdge) => decodeHEIC(file, {}, maxEdge)
