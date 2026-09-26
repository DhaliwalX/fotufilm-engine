import { convertVideoFrame } from './video-color-client.js'
import { canvasBlob } from './geometry.js'

export const checkAbort = (signal) => {
  if (signal?.aborted)
    throw new DOMException('Video operation cancelled.', 'AbortError')
}

// `size`, in displayed orientation, converts straight to that size, resampled as
// `rawSource` would resample the full frame; otherwise the frame is converted whole.
export async function sampleImage(sample, encoding, size = null) {
  const { width, height } = sample.visibleRect
  if (width * height > 40000000)
    throw new Error('Video frames above 40 megapixels are not supported.')
  if (!sample.format)
    throw new Error(
      'This browser cannot expose the decoded video pixels without color conversion. Try a supported codec or browser.',
    )
  const data = new Uint8Array(sample.allocationSize())
  const layout = await sample.copyTo(data)
  return convertVideoFrame(
    {
      data,
      layout,
      format: sample.format,
      width,
      height,
      colorSpace: sample.colorSpace,
      rotation: sample.rotation,
      displayWidth: size?.width ?? sample.displayWidth,
      displayHeight: size?.height ?? sample.displayHeight,
    },
    encoding,
  )
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
    const cursor = playbackCursor(sink)
    const clip = {
      file,
      input,
      track,
      sink,
      duration,
      start,
      playbackUrl,
      closed: false,
      async frame(time, encoding, size = null) {
        if (this.closed) throw new DOMException('Video closed.', 'AbortError')
        const sample = await cursor.sample(
          Math.max(start, Math.min(duration - 0.000001, time)),
        )
        if (!sample) throw new Error('No video frame at this time.')
        try {
          return await sampleImage(sample, encoding, size)
        } finally {
          sample.close()
        }
      },
      dispose() {
        this.closed = true
        cursor.close()
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

// Playback asks for frames in order. Seeking decodes from the keyframe before each
// requested time, so every frame of a long-GOP clip cost the frames before it in
// its group of pictures. The cursor keeps one decode running forward instead and
// restarts it only for a step back or a jump. It returns what `getSample` would:
// the last frame starting at or before the time, as a clone the caller closes.
const CURSOR_JUMP_SECONDS = 2
// Frame times are rounded to the container's timescale, so a time on a frame
// boundary can fall a hair short of the frame's own timestamp.
const TIMESTAMP_TOLERANCE = 1e-6
export function playbackCursor(sink) {
  let iterator = null,
    current = null,
    next = null,
    last = -Infinity,
    queue = Promise.resolve()
  const reset = async () => {
    current?.close()
    next?.close()
    current = next = null
    await iterator?.return()
    iterator = null
  }
  const advance = async () => {
    const step = await iterator.next()
    return step.done ? null : step.value
  }
  const seek = async (time) => {
    if (!iterator || time < last || time - last > CURSOR_JUMP_SECONDS) {
      await reset()
      iterator = sink.samples(time)
      current = await advance()
      next = current && (await advance())
      if (current && current.timestamp > time + TIMESTAMP_TOLERANCE) {
        // Before the first frame: nothing starts at or before the time.
        last = -Infinity
        return null
      }
    }
    while (next && next.timestamp <= time + TIMESTAMP_TOLERANCE) {
      current.close()
      current = next
      next = await advance()
    }
    last = time
    return current?.clone() ?? null
  }
  return {
    sample(time) {
      const result = queue.then(() => seek(time))
      queue = result.catch(() => reset())
      return result
    },
    close() {
      queue = queue.then(reset)
    },
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
