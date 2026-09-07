import { yieldToBrowser } from './yield.js'
import { clamp } from './color-controls.js'
import { validCrop } from './editor-state.js'

export function outputSize(points, width, height) {
  const distance = (a, b) => Math.hypot((a[0] - b[0]) * width, (a[1] - b[1]) * height)
  return {
    width: Math.max(
      1,
      Math.round((distance(points[0], points[1]) + distance(points[3], points[2])) / 2),
    ),
    height: Math.max(
      1,
      Math.round((distance(points[0], points[3]) + distance(points[1], points[2])) / 2),
    ),
  }
}
// Unit square → quadrilateral homography. Preview and export share this mapping.
export function homography(points) {
  if (!validCrop(points)) throw new Error('Invalid crop selection.')
  const [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = points
  const dx1 = x1 - x2,
    dx2 = x3 - x2,
    sx = x0 - x1 + x2 - x3
  const dy1 = y1 - y2,
    dy2 = y3 - y2,
    sy = y0 - y1 + y2 - y3
  const determinant = dx1 * dy2 - dx2 * dy1
  const g = (sx * dy2 - dx2 * sy) / determinant
  const h = (dx1 * sy - sx * dy1) / determinant
  return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h]
}
export function mapPoint(matrix, u, v) {
  const denominator = matrix[6] * u + matrix[7] * v + 1
  return [
    (matrix[0] * u + matrix[1] * v + matrix[2]) / denominator,
    (matrix[3] * u + matrix[4] * v + matrix[5]) / denominator,
  ]
}
export function orientImage(image, edit, maxEdge = Infinity) {
  const w = image.naturalWidth || image.width,
    h = image.naturalHeight || image.height
  const scale = Math.min(1, maxEdge / Math.max(w, h))
  const swapped = edit.rotation % 2 !== 0
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round((swapped ? h : w) * scale))
  canvas.height = Math.max(1, Math.round((swapped ? w : h) * scale))
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  ctx.translate(canvas.width / 2, canvas.height / 2)
  ctx.scale(edit.flip ? -1 : 1, 1)
  ctx.rotate((-edit.rotation * Math.PI) / 2)
  ctx.drawImage(image, (-w * scale) / 2, (-h * scale) / 2, w * scale, h * scale)
  return canvas
}
export async function cropImage(canvas, edit) {
  let result = canvas
  if (edit.crop.some((p, i) => p[0] !== [0, 1, 1, 0][i] || p[1] !== [0, 0, 1, 1][i])) {
    const size = outputSize(edit.crop, canvas.width, canvas.height)
    const mapped = homography(edit.crop)
    const source = canvas
      .getContext('2d', { willReadFrequently: true })
      .getImageData(0, 0, canvas.width, canvas.height).data
    result = document.createElement('canvas')
    result.width = size.width
    result.height = size.height
    const ctx = result.getContext('2d'),
      output = ctx.createImageData(size.width, size.height)
    for (let y = 0; y < size.height; y++) {
      for (let x = 0; x < size.width; x++) {
        const [u, v] = mapPoint(mapped, (x + 0.5) / size.width, (y + 0.5) / size.height)
        const sx = clamp(u * canvas.width - 0.5, 0, canvas.width - 1),
          sy = clamp(v * canvas.height - 0.5, 0, canvas.height - 1)
        const ix = Math.floor(sx),
          iy = Math.floor(sy),
          fx = sx - ix,
          fy = sy - iy
        const nextX = Math.min(ix + 1, canvas.width - 1),
          nextY = Math.min(iy + 1, canvas.height - 1)
        for (let c = 0; c < 4; c++) {
          const a = source[(iy * canvas.width + ix) * 4 + c],
            b = source[(iy * canvas.width + nextX) * 4 + c]
          const d = source[(nextY * canvas.width + ix) * 4 + c],
            e = source[(nextY * canvas.width + nextX) * 4 + c]
          output.data[(y * size.width + x) * 4 + c] =
            (a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy
        }
      }
      if (y % 128 === 0) await yieldToBrowser()
    }
    ctx.putImageData(output, 0, 0)
  }
  if (edit.straighten) {
    const angle = (edit.straighten * Math.PI) / 180
    const rotated = document.createElement('canvas')
    rotated.width = result.width
    rotated.height = result.height
    const ctx = rotated.getContext('2d')
    // Cover the frame after rotation so straightening never adds transparent corners.
    const scale = Math.max(
      (result.width * Math.cos(angle) + result.height * Math.abs(Math.sin(angle))) / result.width,
      (result.height * Math.cos(angle) + result.width * Math.abs(Math.sin(angle))) / result.height,
    )
    ctx.translate(result.width / 2, result.height / 2)
    ctx.rotate(angle)
    ctx.scale(scale, scale)
    ctx.drawImage(result, -result.width / 2, -result.height / 2)
    result = rotated
  }
  return result
}
export const canvasBlob = (canvas, type = 'image/png', quality = 0.95) =>
  new Promise((resolve, reject) =>
    canvas.toBlob(
      (blob) => {
        if (!blob) reject(new Error('Could not encode this image. Try a smaller export size.'))
        else if (blob.type !== type)
          reject(new Error('This browser cannot export that format. Choose PNG.'))
        else resolve(blob)
      },
      type,
      quality,
    ),
  )
