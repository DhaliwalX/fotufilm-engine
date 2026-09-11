import { decodeVideoPlanes } from './video-color.js'
import { canvasBlob } from './geometry.js'

export const VIDEO_ACCEPT = 'video/*,.mp4,.mov,.m4v,.webm,.mkv'
export const isVideoFile = (file) =>
  file.type.startsWith('video/') || /\.(mp4|mov|m4v|webm|mkv)$/i.test(file.name)
export const checkAbort = (signal) => {
  if (signal?.aborted)
    throw new DOMException('Video operation cancelled.', 'AbortError')
}

export async function sampleImage(sample, encoding) {
  const { width, height } = sample.visibleRect
  if (width * height > 40000000)
    throw new Error('Video frames above 40 megapixels are not supported.')
  if (!sample.format)
    throw new Error(
      'This browser cannot expose the decoded video pixels without color conversion. Try a supported codec or browser.',
    )
  const data = new Uint8Array(sample.allocationSize())
  const layout = await sample.copyTo(data)
  const decoded = decodeVideoPlanes(
    {
      data,
      layout,
      format: sample.format,
      width,
      height,
      colorSpace: sample.colorSpace,
    },
    encoding,
  )
  const rotation = sample.rotation
  const displayWidth = sample.displayWidth,
    displayHeight = sample.displayHeight
  if (rotation === 0 && displayWidth === width && displayHeight === height)
    return {
      naturalWidth: width,
      naturalHeight: height,
      linear: { data: decoded, colors: 4 },
    }
  // Apply container orientation and pixel aspect ratio in float, after the input
  // curve. Geometry in the editor then operates in the displayed coordinate system.
  const pixels = new Float32Array(displayWidth * displayHeight * 4)
  for (let y = 0; y < displayHeight; y++)
    for (let x = 0; x < displayWidth; x++) {
      let u = (x + 0.5) / displayWidth,
        v = (y + 0.5) / displayHeight
      if (rotation === 90) [u, v] = [v, 1 - u]
      else if (rotation === 180) [u, v] = [1 - u, 1 - v]
      else if (rotation === 270) [u, v] = [1 - v, u]
      const sx = Math.max(0, Math.min(width - 1, u * width - 0.5)),
        sy = Math.max(0, Math.min(height - 1, v * height - 0.5))
      const ix = Math.floor(sx),
        iy = Math.floor(sy),
        nx = Math.min(ix + 1, width - 1),
        ny = Math.min(iy + 1, height - 1)
      const fx = sx - ix,
        fy = sy - iy,
        target = (y * displayWidth + x) * 4
      for (let c = 0; c < 4; c++)
        pixels[target + c] =
          ((1 - fx) * decoded[(iy * width + ix) * 4 + c] +
            fx * decoded[(iy * width + nx) * 4 + c]) *
            (1 - fy) +
          ((1 - fx) * decoded[(ny * width + ix) * 4 + c] +
            fx * decoded[(ny * width + nx) * 4 + c]) *
            fy
    }
  return {
    naturalWidth: displayWidth,
    naturalHeight: displayHeight,
    linear: { data: pixels, colors: 4 },
  }
}

export async function importVideo(
  file,
  { signal, onProgress = () => {} } = {},
) {
  if (typeof VideoDecoder === 'undefined')
    throw new Error(
      'Video editing requires WebCodecs. Open the editor in a current Chrome, Edge, or Safari browser.',
    )
  checkAbort(signal)
  onProgress('Reading video metadata')
  const {
    Input,
    BlobSource,
    ALL_FORMATS,
    VideoSampleSink,
    MatroskaInputFormat,
  } = await import('mediabunny')
  checkAbort(signal)
  const input = new Input({
    source: new BlobSource(file, { maxCacheSize: 8 * 1024 * 1024 }),
    formats: ALL_FORMATS,
  })
  const abort = () => input.dispose()
  signal?.addEventListener('abort', abort, { once: true })
  let posterUrl, playbackUrl
  try {
    const track = await input.getPrimaryVideoTrack()
    if (!track) throw new Error('This file has no video track.')
    const codec = await track.getCodec()
    if (codec === 'hevc' && !(await track.canDecode())) {
      onProgress('Loading software HEVC decoder')
      ;(await import('./hevc-decoder.js')).registerSoftwareHEVC()
    }
    if (!(await track.canDecode()))
      throw new Error(
        `This browser cannot decode ${(await track.getCodec()) || 'this codec'}. Try a supported H.264, HEVC, VP9, or AV1 file.`,
      )
    // MP4 edit-list metadata can include an extra decode-reordering interval.
    // Use actual packet timing; Matroska needs its declared end when the final
    // SimpleBlock has no duration. Neither operation decodes or buffers the clip.
    const duration =
      (await input.getFormat()) instanceof MatroskaInputFormat
        ? ((await track.getDurationFromMetadata()) ??
          (await track.computeDuration()))
        : await track.computeDuration()
    const start = Math.max(0, await track.getFirstTimestamp())
    if (!Number.isFinite(duration) || duration <= start)
      throw new Error('This video has no playable duration.')
    const width = await track.getDisplayWidth(),
      height = await track.getDisplayHeight()
    if (width * height > 40000000)
      throw new Error('Video frames above 40 megapixels are not supported.')
    let sink = new VideoSampleSink(track)
    let sample, decodeError
    try {
      sample = await sink.getSample(start)
    } catch (error) {
      decodeError = error
    }
    if ((decodeError || !sample?.format) && codec === 'hevc') {
      sample?.close()
      onProgress('Loading software HEVC decoder to preserve ten-bit color')
      ;(await import('./hevc-decoder.js')).registerSoftwareHEVC()
      checkAbort(signal)
      sink = new VideoSampleSink(track)
      sample = await sink.getSample(start)
    } else if (decodeError) throw decodeError
    if (!sample) throw new Error('The first video frame could not be decoded.')
    try {
      // A small thumbnail is display-only. Film preview/export always read native planes.
      const canvas = document.createElement('canvas'),
        scale = Math.min(1, 320 / Math.max(width, height))
      canvas.width = Math.max(1, Math.round(width * scale))
      canvas.height = Math.max(1, Math.round(height * scale))
      sample.draw(canvas.getContext('2d'), 0, 0, canvas.width, canvas.height)
      posterUrl = URL.createObjectURL(await canvasBlob(canvas))
    } finally {
      sample.close()
    }
    checkAbort(signal)
    playbackUrl = URL.createObjectURL(file)
    const clip = {
      file,
      input,
      track,
      sink,
      duration,
      start,
      playbackUrl,
      closed: false,
      async frame(time, encoding) {
        if (this.closed) throw new DOMException('Video closed.', 'AbortError')
        const sample = await sink.getSample(
          Math.max(start, Math.min(duration - 0.000001, time)),
        )
        if (!sample) throw new Error('No video frame at this time.')
        try {
          return await sampleImage(sample, encoding)
        } finally {
          sample.close()
        }
      },
      dispose() {
        this.closed = true
        input.dispose()
        URL.revokeObjectURL(playbackUrl)
        URL.revokeObjectURL(posterUrl)
      },
    }
    return {
      image: {
        naturalWidth: width,
        naturalHeight: height,
        src: posterUrl,
        video: clip,
      },
      url: posterUrl,
    }
  } catch (error) {
    input.dispose()
    if (posterUrl) URL.revokeObjectURL(posterUrl)
    if (playbackUrl) URL.revokeObjectURL(playbackUrl)
    checkAbort(signal)
    throw error
  } finally {
    signal?.removeEventListener('abort', abort)
  }
}

// WebM SimpleBlocks can omit a frame duration. A single lookahead recovers it
// from the next timestamp, using the container end for the final frame.
export async function* timedVideoSamples(sink, start, end) {
  const iterator = sink.samples(start, end)
  let pending
  try {
    pending = await iterator.next()
    while (!pending.done) {
      const sample = pending.value
      pending = null
      try {
        pending = await iterator.next()
        const sampleEnd =
          sample.duration > 0
            ? sample.timestamp + sample.duration
            : pending.done
              ? end
              : pending.value.timestamp
        yield {
          sample,
          from: Math.max(start, sample.timestamp),
          to: Math.min(end, sampleEnd),
        }
      } finally {
        sample.close()
      }
    }
  } finally {
    pending?.value?.close()
    await iterator.return()
  }
}
