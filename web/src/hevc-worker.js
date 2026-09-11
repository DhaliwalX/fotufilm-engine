// Classic worker: load the pinned decoder's unmodified UMD factory with
// importScripts. Only encoded packets and copied YUV planes cross this boundary.
let module, decoder, api
function frames(flush) {
  let count, pointer
  if (flush) {
    const status = api.flush(decoder)
    if (status !== 0) throw new Error(`HEVC flush failed (${status}).`)
  }
  if (flush) count = 64
  else {
    pointer = module._malloc(4)
    try {
      const status = api.drain(decoder, pointer)
      if (status !== 0) throw new Error(`HEVC frame read failed (${status}).`)
      count = module.getValue(pointer, 'i32')
    } finally {
      module._free(pointer)
    }
  }
  if (count < 0 || count > 64) throw new Error('Invalid HEVC frame queue.')
  const output = []
  for (let index = 0; index < count; index++) {
    pointer = module._malloc(48)
    try {
      if (api.frame(decoder, index, pointer) !== 0) {
        if (flush) break
        throw new Error('Could not read a decoded HEVC frame.')
      }
      const integer = (offset) => module.getValue(pointer + offset, 'i32')
      const width = integer(12),
        height = integer(16),
        cw = integer(28),
        ch = integer(32),
        depth = integer(36)
      if (
        width <= 0 ||
        height <= 0 ||
        width * height > 40000000 ||
        ![8, 10].includes(depth) ||
        cw !== Math.ceil(width / 2) ||
        ch !== Math.ceil(height / 2)
      )
        throw new Error(
          'Software HEVC decoding supports Main / Main10 4:2:0 frames up to 40 megapixels.',
        )
      const bytes = depth === 8 ? 1 : 2
      const data = new Uint8Array((width * height + 2 * cw * ch) * bytes),
        view = new DataView(data.buffer)
      const layout = [],
        sizes = [
          [width, height, integer(20)],
          [cw, ch, integer(24)],
          [cw, ch, integer(24)],
        ]
      let offset = 0
      for (let plane = 0; plane < 3; plane++) {
        const [w, h, stride] = sizes[plane],
          base = module.getValue(pointer + plane * 4, '*') / 2
        layout.push({ offset, stride: w * bytes })
        for (let y = 0; y < h; y++)
          for (let x = 0; x < w; x++) {
            const value = module.HEAPU16[base + y * stride + x]
            if (bytes === 2) view.setUint16(offset, value, true)
            else data[offset] = value
            offset += bytes
          }
      }
      output.push({ data, layout, width, height, depth })
    } finally {
      module._free(pointer)
    }
  }
  return output
}
self.onmessage = async ({ data: message }) => {
  try {
    let output = []
    if (message.type === 'init') {
      importScripts(message.factoryUrl)
      module = await self.HEVCDecoderModule({
        locateFile: () => message.wasmUrl,
      })
      const wrap = (name, args) =>
        module.cwrap(
          `hevc_decoder_${name}`,
          'number',
          args.map(() => 'number'),
        )
      api = {
        create: wrap('create', []),
        feed: wrap('feed', [0, 0, 0]),
        drain: wrap('drain', [0, 0]),
        frame: wrap('get_drained_frame', [0, 0, 0]),
        flush: wrap('flush', [0]),
      }
      decoder = api.create()
      if (!decoder) throw new Error('Could not initialize the HEVC decoder.')
    } else if (message.type === 'decode') {
      const bytes = new Uint8Array(message.data),
        pointer = module._malloc(bytes.length)
      try {
        module.HEAPU8.set(bytes, pointer)
        const status = api.feed(decoder, pointer, bytes.length)
        if (status !== 0) throw new Error(`HEVC decoding failed (${status}).`)
      } finally {
        module._free(pointer)
      }
      output = frames(false)
    } else if (message.type === 'flush') output = frames(true)
    self.postMessage(
      { id: message.id, frames: output },
      output.map((frame) => frame.data.buffer),
    )
  } catch (error) {
    self.postMessage({
      id: message.id,
      error: error.message || 'HEVC decoding failed.',
    })
  }
}
