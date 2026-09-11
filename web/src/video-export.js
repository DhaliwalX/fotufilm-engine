import { sampleImage, checkAbort, timedVideoSamples } from './video-import.js'
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

// Invoked directly by the Export click to retain the save picker's user activation.
// StreamTarget closes its stream even on cancel, so its close is deliberately NOT
// allowed to commit the file. Only finish(), after muxer finalization, commits it.
export async function createVideoDestination(filename) {
  let handle, directory, temporaryName
  if (window.showSaveFilePicker) {
    handle = await window.showSaveFilePicker({
      suggestedName: filename,
      types: [
        {
          description: 'Video',
          accept: {
            [filename.endsWith('.webm') ? 'video/webm' : 'video/mp4']: [
              filename.endsWith('.webm') ? '.webm' : '.mp4',
            ],
          },
        },
      ],
    })
  } else {
    if (!navigator.storage?.getDirectory)
      throw new Error(
        'Disk-backed video export is unavailable. Use Chrome or Edge with file-system access.',
      )
    directory = await (
      await navigator.storage.getDirectory()
    ).getDirectoryHandle('fotufilm-video-exports', { create: true })
    temporaryName = `${crypto.randomUUID()}.${filename.endsWith('.webm') ? 'webm' : 'mp4'}`
    handle = await directory.getFileHandle(temporaryName, { create: true })
  }
  let writable, target
  try {
    writable = await handle.createWritable()
    const { StreamTarget } = await import('mediabunny')
    target = new StreamTarget(
      new WritableStream({ write: (chunk) => writable.write(chunk) }),
      { chunked: true, chunkSize: 1024 * 1024 },
    )
  } catch (error) {
    await writable?.abort().catch(() => {})
    if (directory) await directory.removeEntry(temporaryName).catch(() => {})
    throw error
  }
  let committed = false,
    url = null,
    disposed = false
  return {
    target,
    async finish() {
      await writable.close()
      committed = true
      if (directory) url = URL.createObjectURL(await handle.getFile())
      return { url, filename, dispose: this.dispose.bind(this) }
    },
    async dispose() {
      if (disposed) return
      disposed = true
      if (!committed) await writable.abort().catch(() => {})
      if (url) URL.revokeObjectURL(url)
      if (directory) await directory.removeEntry(temporaryName).catch(() => {})
    },
  }
}

export async function exportVideo({
  image,
  edit,
  stock,
  session,
  destination,
  format = 'mp4',
  maxEdge = Infinity,
  quality = 'high',
  signal,
  onProgress = () => {},
}) {
  let output, audio, iterator, videoInput
  const abort = () => {
    videoInput?.dispose()
    audio?.cancel().catch(() => {})
  }
  signal?.addEventListener('abort', abort, { once: true })
  try {
    const {
      Output,
      Mp4OutputFormat,
      WebMOutputFormat,
      VideoSampleSource,
      VideoSample,
      Conversion,
      Quality,
      canEncodeVideo,
      Input,
      BlobSource,
      ALL_FORMATS,
      VideoSampleSink,
    } = await import('mediabunny')
    checkAbort(signal)
    const clip = image.video,
      { start, end } = videoRange(clip, edit.video)
    const dimensions = videoDimensions(image, edit, maxEdge),
      codec = format === 'webm' ? 'vp9' : 'avc'
    if (!(await canEncodeVideo(codec, dimensions)))
      throw new Error(
        `This browser cannot encode ${codec.toUpperCase()} at ${dimensions.width} × ${dimensions.height}. Choose a smaller size or another format.`,
      )
    output = new Output({
      format:
        format === 'webm'
          ? new WebMOutputFormat()
          : new Mp4OutputFormat({
              fastStart: 'fragmented',
              minimumFragmentDuration: 1,
            }),
      target: destination.target,
    })
    const source = new VideoSampleSource({
      codec,
      quality: new Quality(quality),
      keyFrameInterval: 1,
    })
    output.addVideoTrack(source)
    // Let the library handle audio codecs, per-track offsets and sample-accurate
    // trimming. Advance it in lockstep with video to keep muxer buffers bounded.
    audio = await Conversion.init({
      input: clip.input,
      output,
      composable: true,
      tracks: 'all',
      video: { discard: true },
      audio: { discard: !edit.video.audio },
      trim: { start, end },
      showWarnings: false,
    })
    const discarded = audio.discardedTracks.filter(
      (item) => item.reason !== 'discarded_by_user',
    )
    if (discarded.length)
      throw new Error(
        `Audio cannot be preserved in this format (${discarded.map((item) => item.reason).join(', ')}). Choose another format or turn off Include audio.`,
      )
    checkAbort(signal)
    await output.start()
    const canvas = document.createElement('canvas')
    Object.assign(canvas, dimensions)
    const context = canvas.getContext('2d')
    let frames = 0
    videoInput = new Input({
      source: new BlobSource(clip.file, { maxCacheSize: 8 * 1024 * 1024 }),
      formats: ALL_FORMATS,
    })
    checkAbort(signal)
    const videoTrack = await videoInput.getPrimaryVideoTrack()
    iterator = timedVideoSamples(new VideoSampleSink(videoTrack), start, end)
    for await (const { sample, from, to } of iterator) {
      try {
        checkAbort(signal)
        if (from >= to) continue
        const frame = await sampleImage(sample, edit.video.encoding)
        checkAbort(signal)
        const rendered = await session.render({
          image: frame,
          edit: { ...edit, seed: (edit.seed + frames) >>> 0 },
          stock,
          maxEdge,
          comparison: false,
          encode: false,
          cacheSource: false,
          purpose: 'video export',
          stale: () => !!signal?.aborted,
        })
        checkAbort(signal)
        if (!rendered) throw new Error('Video frame rendering stopped.')
        context.fillStyle = 'black'
        context.fillRect(0, 0, canvas.width, canvas.height)
        context.drawImage(rendered.canvas, 0, 0)
        const encoded = new VideoSample(canvas, {
          timestamp: from - start,
          duration: to - from,
        })
        try {
          await source.add(encoded)
        } finally {
          encoded.close()
        }
        await audio.execute({ until: to - start })
        frames++
        onProgress({
          progress: (to - start) / (end - start),
          frames,
          time: to - start,
        })
      } finally {
        sample.close()
      }
    }
    if (!frames) throw new Error('The selected range has no video frames.')
    checkAbort(signal)
    source.close()
    await audio.execute()
    checkAbort(signal)
    onProgress({ progress: 1, frames, finalizing: true })
    await output.finalize()
    checkAbort(signal)
    return await destination.finish()
  } catch (error) {
    await audio?.cancel().catch(() => {})
    if (output && output.state !== 'finalized')
      await output.cancel().catch(() => {})
    await destination.dispose()
    checkAbort(signal)
    throw error
  } finally {
    await iterator?.return().catch(() => {})
    videoInput?.dispose()
    signal?.removeEventListener('abort', abort)
  }
}
