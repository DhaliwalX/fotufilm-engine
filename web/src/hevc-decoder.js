import { CustomVideoDecoder, VideoSample, registerDecoder } from 'mediabunny'
import { hevcAssets } from './hevc-assets.js'
import { hevcConfiguration, packetBytes } from './hevc-bitstream.js'

class SoftwareHEVCDecoder extends CustomVideoDecoder {
  static supports(codec) {
    return codec === 'hevc'
  }
  async init() {
    this.pending = new Map()
    this.sequence = 0
    this.times = []
    this.worker = new Worker(new URL('./hevc-worker.js', import.meta.url))
    this.worker.onmessage = ({ data }) => {
      const pending = this.pending.get(data.id)
      if (!pending) return
      this.pending.delete(data.id)
      data.error
        ? pending.reject(new Error(data.error))
        : pending.resolve(data.frames)
    }
    this.worker.onerror = () => {
      const error = new Error('The software HEVC decoder could not run.')
      for (const pending of this.pending.values()) pending.reject(error)
      this.pending.clear()
      this.onError(error)
    }
    await this.call({ type: 'init', ...hevcAssets() })
    const { lengthSize, parameters } = hevcConfiguration(
      this.config.description,
    )
    this.lengthSize = lengthSize
    if (parameters.length)
      await this.call({ type: 'decode', data: parameters.buffer }, [
        parameters.buffer,
      ])
  }
  call(message, transfer = []) {
    if (this.closed)
      return Promise.reject(
        new DOMException('HEVC decoder closed.', 'AbortError'),
      )
    const id = ++this.sequence
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.worker.postMessage({ ...message, id }, transfer)
    })
  }
  emit(frames) {
    for (const frame of frames) {
      this.times.sort((a, b) => a.timestamp - b.timestamp)
      const time = this.times.shift()
      if (!time) throw new Error('HEVC frame has no presentation timestamp.')
      const sample = new VideoSample(frame.data, {
        format: frame.depth === 10 ? 'I420P10' : 'I420',
        codedWidth: frame.width,
        codedHeight: frame.height,
        layout: frame.layout,
        timestamp: time.timestamp,
        duration: time.duration,
        colorSpace: this.config.colorSpace,
        displayWidth: this.config.displayAspectWidth || frame.width,
        displayHeight: this.config.displayAspectHeight || frame.height,
      })
      this.onSample(sample)
    }
  }
  async decode(packet) {
    this.times.push({ timestamp: packet.timestamp, duration: packet.duration })
    if (this.times.length > 64)
      throw new Error('HEVC decoder exceeded its frame reorder limit.')
    const data = packetBytes(packet.data, this.lengthSize)
    this.emit(
      await this.call({ type: 'decode', data: data.buffer }, [data.buffer]),
    )
  }
  async flush() {
    this.emit(await this.call({ type: 'flush' }))
  }
  close() {
    this.closed = true
    this.worker?.terminate()
    for (const pending of this.pending?.values() || [])
      pending.reject(new DOMException('HEVC decoder closed.', 'AbortError'))
    this.pending?.clear()
    this.times = []
  }
}
let registered = false
export function registerSoftwareHEVC() {
  if (!registered) {
    registerDecoder(SoftwareHEVCDecoder)
    registered = true
  }
}
