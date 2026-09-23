import { outputSize } from './geometry.js'

export function videoRange(clip, settings) {
  const start = Math.max(clip.start, settings.trimStart),
    end = Math.min(clip.duration, settings.trimEnd ?? clip.duration)
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end)
    throw new Error('Trim out must be after trim in and inside the clip.')
  return { start, end }
}
export function videoDimensions(image, edit, maxEdge) {
  const width = edit.rotation % 2 ? image.naturalHeight : image.naturalWidth
  const height = edit.rotation % 2 ? image.naturalWidth : image.naturalHeight
  const scale = Math.min(1, maxEdge / Math.max(width, height))
  const size = outputSize(
    edit.crop,
    Math.round(width * scale),
    Math.round(height * scale),
  )
  // 4:2:0 codecs require even dimensions. Pad at most one pixel, never change aspect ratio.
  return {
    width: Math.max(2, Math.ceil(size.width / 2) * 2),
    height: Math.max(2, Math.ceil(size.height / 2) * 2),
  }
}

