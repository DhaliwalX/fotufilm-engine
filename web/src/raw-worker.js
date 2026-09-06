// One worker per import releases the decoder's entire WASM heap on completion.
self.onmessage = async ({ data: { bytes, decoderURL } }) => {
  let module, input
  try {
    const factory = (await import(/* @vite-ignore */ decoderURL)).default
    module = await factory()
    input = module._malloc(bytes.byteLength)
    if (!input) throw new Error('Not enough memory to open this RAW image.')
    module.HEAPU8.set(new Uint8Array(bytes), input)
    if (module._raw_open(input, bytes.byteLength))
      throw new Error(module.UTF8ToString(module._raw_error()))
    self.postMessage({ status: 'Reading RAW sensor' })
    if (module._raw_unpack()) throw new Error(module.UTF8ToString(module._raw_error()))
    self.postMessage({ status: 'Developing RAW' })
    if (module._raw_process()) throw new Error(module.UTF8ToString(module._raw_error()))
    const width = module._raw_width(),
      height = module._raw_height(),
      colors = module._raw_colors()
    self.postMessage({ status: 'Preparing RAW preview' })
    const start = module._raw_pixels() / 2
    const pixels = module.HEAPU16.slice(start, start + width * height * colors)
    self.postMessage({ width, height, colors, pixels }, [pixels.buffer])
  } catch (error) {
    self.postMessage({ error: error.message || 'Could not decode RAW image.' })
  } finally {
    module?._raw_close()
    if (input) module._free(input)
  }
}
