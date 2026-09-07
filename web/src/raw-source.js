import { fullCrop } from './editor-state.js'
import { homography, mapPoint, outputSize } from './geometry.js'

// RAW storage remains RGB16. Geometry reads linear Rec.2020 float tiles directly;
// a canvas is used only for display, never as an intermediate for film or export.
export function rawSource(image, edit, maxEdge = Infinity, cropMode = false) {
  const originalWidth = image.naturalWidth,
    originalHeight = image.naturalHeight
  const swapped = edit.rotation % 2 !== 0
  const orientedWidth = swapped ? originalHeight : originalWidth
  const orientedHeight = swapped ? originalWidth : originalHeight
  const scale = Math.min(1, maxEdge / Math.max(orientedWidth, orientedHeight))
  const frameWidth = Math.max(1, Math.round(orientedWidth * scale))
  const frameHeight = Math.max(1, Math.round(orientedHeight * scale))
  const crop = cropMode ? fullCrop() : edit.crop
  const { width, height } = outputSize(crop, frameWidth, frameHeight)
  const matrix = homography(crop)
  const angle = cropMode ? 0 : (edit.straighten * Math.PI) / 180
  const cos = Math.cos(angle),
    sin = Math.sin(angle)
  const cover = Math.max(
    (width * cos + height * Math.abs(sin)) / width,
    (height * cos + width * Math.abs(sin)) / height,
  )
  const { data, colors } = image.raw
  function point(u, v) {
    const px = ((u - 0.5) * width) / cover,
      py = ((v - 0.5) * height) / cover
    ;[u, v] = mapPoint(
      matrix,
      (cos * px + sin * py) / width + 0.5,
      (-sin * px + cos * py) / height + 0.5,
    )
    if (edit.flip) u = 1 - u
    switch (edit.rotation) {
      case 1:
        return [1 - v, u]
      case 2:
        return [1 - u, 1 - v]
      case 3:
        return [v, 1 - u]
      default:
        return [u, v]
    }
  }
  return {
    width,
    height,
    read(left, top, w, h) {
      const output = new Float32Array(w * h * 4)
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          const [u, v] = point((left + x + 0.5) / width, (top + y + 0.5) / height)
          const sx = Math.max(0, Math.min(originalWidth - 1, u * originalWidth - 0.5))
          const sy = Math.max(0, Math.min(originalHeight - 1, v * originalHeight - 0.5))
          const ix = Math.floor(sx),
            iy = Math.floor(sy),
            fx = sx - ix,
            fy = sy - iy
          const nx = Math.min(ix + 1, originalWidth - 1),
            ny = Math.min(iy + 1, originalHeight - 1)
          const i = (y * w + x) * 4
          for (let c = 0; c < 3; c++) {
            const channel = colors === 1 ? 0 : c
            const a = data[(iy * originalWidth + ix) * colors + channel]
            const b = data[(iy * originalWidth + nx) * colors + channel]
            const d = data[(ny * originalWidth + ix) * colors + channel]
            const e = data[(ny * originalWidth + nx) * colors + channel]
            output[i + c] = ((a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy) / 65535
          }
          output[i + 3] = 1
        }
      return output
    },
  }
}
