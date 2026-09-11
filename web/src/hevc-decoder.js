import { CustomVideoDecoder, VideoSample, registerDecoder } from 'mediabunny'
import factoryUrl from '../node_modules/@hevcjs/core/dist/wasm/hevc-decode.js?url'
import wasmUrl from '../node_modules/@hevcjs/core/dist/wasm/hevc-decode.wasm?url'
import workerUrl from './hevc-worker.js?url'

// hvcC stores parameter sets and the packet NAL-length width. Feed Annex B to
// the software decoder, retaining presentation timestamps from the demuxer.
export function hevcConfiguration(description) {
  if (!description) return { lengthSize: 0, parameters: new Uint8Array() }
  const data = new Uint8Array(
    description.buffer ?? description,
    description.byteOffset ?? 0,
    description.byteLength,
  )
  if (data.length < 23 || data[0] !== 1)
    throw new Error('Invalid HEVC configuration.')
  let position = 23
  const nals = []
  const word = () => {
    if (position + 2 > data.length)
      throw new Error('Truncated HEVC configuration.')
    const value = data[position] * 256 + data[position + 1]
    position += 2
    return value
  }
  for (let array = 0; array < data[22]; array++) {
    if (position >= data.length)
      throw new Error('Truncated HEVC parameter sets.')
    position++
    const count = word()
    for (let i = 0; i < count; i++) {
      const length = word()
      if (length < 2 || position + length > data.length)
        throw new Error('Invalid HEVC parameter set.')
      nals.push(data.subarray(position, position + length))
      position += length
    }
  }
  return { lengthSize: (data[21] & 3) + 1, parameters: annexB(nals) }
}
function annexB(nals) {
  const data = new Uint8Array(
    nals.reduce((length, nal) => length + nal.length + 4, 0),
  )
  let offset = 0
  for (const nal of nals) {
    data.set([0, 0, 0, 1], offset)
    data.set(nal, offset + 4)
    offset += nal.length + 4
  }
  return data
}
function packetBytes(data, lengthSize) {
  if (!lengthSize) return data.slice()
  const nals = []
  for (let offset = 0; offset < data.length; ) {
    if (offset + lengthSize > data.length)
      throw new Error('Truncated HEVC packet.')
    let length = 0
    for (let i = 0; i < lengthSize; i++) length = length * 256 + data[offset++]
    if (length < 2 || offset + length > data.length)
      throw new Error('Invalid HEVC packet.')
    nals.push(data.subarray(offset, offset + length))
    offset += length
  }
  return annexB(nals)
}

class SoftwareHEVCDecoder extends CustomVideoDecoder {
  static supports(codec) {
    return codec === 'hevc'
  }
  async init() {
    this.pending = new Map()
    this.sequence = 0
    this.times = []
    this.worker = new Worker(workerUrl)
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
    await this.call({
      type: 'init',
      factoryUrl: new URL(factoryUrl, location.href).href,
      wasmUrl: new URL(wasmUrl, location.href).href,
    })
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
