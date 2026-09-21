import { defaultEdit } from './editor-state.js'
import { rawSource } from './raw-source.js'
import { developImportPreview } from './normal-preview.js'
import { pixelsCanvas } from './canvas-color.js'
import { canvasBlob } from './geometry.js'

// RAW, EXR and deep raster imports share the same bounded display placeholder.
// The original scene-linear samples remain the input for every later development.
export async function attachLinearPreview(image, options = {}) {
  const source = rawSource(image, defaultEdit(), 1600)
  const { pixels, colorSpace } = await developImportPreview(
    source,
    defaultEdit().params,
    options,
  )
  const blob = await canvasBlob(
    pixelsCanvas(pixels, source.width, source.height, colorSpace),
  )
  if (options.signal?.aborted)
    throw new DOMException('Import cancelled.', 'AbortError')
  const url = URL.createObjectURL(blob)
  image.src = url
  return { image, url }
}
