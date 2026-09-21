import { relatedAssetUrl } from './runtime-assets.js'
import { orientedPixel } from './hdr-color.js'

self.onmessage = async ({ data: { bytes, decoderURL, orientation = 1 } }) => {
  let module, input
  try {
    const factory = (await import(/* @vite-ignore */ decoderURL)).default
    module = await factory({
      locateFile: (name) => relatedAssetUrl(name, decoderURL),
    })
    input = module._malloc(bytes.byteLength)
    if (!input) throw new Error('Not enough memory to read this PNG.')
    module.HEAPU8.set(new Uint8Array(bytes), input)
    self.postMessage({ status: 'Reading 16-bit PNG color profile' })
    const opened = module._png_decoder_open(input, bytes.byteLength)
    if (opened < 0)
      throw new Error(module.UTF8ToString(module._png_decoder_error()))
    if (!opened) {
      self.postMessage({ result: null })
      return
    }
    self.postMessage({ status: 'Decoding 16-bit PNG samples' })
    if (!module._png_decoder_decode())
      throw new Error(module.UTF8ToString(module._png_decoder_error()))
    const sourceWidth = module._png_decoder_width(),
      sourceHeight = module._png_decoder_height()
    const swapped = orientation >= 5 && orientation <= 8
    const width = swapped ? sourceHeight : sourceWidth,
      height = swapped ? sourceWidth : sourceHeight
    const pixels = new Float32Array(width * height * 4),
      rows = module._png_decoder_capacity()
    for (let top = 0; top < sourceHeight; top += rows) {
      self.postMessage({
        status: `Converting PNG to scene-linear color · ${Math.round((top * 100) / sourceHeight)}%`,
      })
      const count = Math.min(rows, sourceHeight - top),
        pointer = module._png_decoder_rows(top, count)
      if (!pointer) throw new Error('PNG color conversion failed.')
      const data = module.HEAPF32.subarray(
        pointer / 4,
        pointer / 4 + sourceWidth * count * 4,
      )
      for (let y = 0; y < count; y++)
        for (let x = 0; x < sourceWidth; x++) {
          const input = (y * sourceWidth + x) * 4
          const [ox, oy] = orientedPixel(
            x,
            top + y,
            sourceWidth,
            sourceHeight,
            orientation,
          )
          const output = (oy * width + ox) * 4,
            alpha = Math.max(0, Math.min(1, data[input + 3]))
          for (let c = 0; c < 3; c++)
            pixels[output + c] = Number.isFinite(data[input + c])
              ? data[input + c] * alpha
              : 0
          pixels[output + 3] = 1 // The engine's input photo is composited over black, as on native.
        }
    }
    self.postMessage({ result: { pixels, width, height } }, [pixels.buffer])
  } catch (error) {
    self.postMessage({
      error: error.message || 'The PNG decoder could not run.',
    })
  } finally {
    module?._png_decoder_close()
    if (input) module._free(input)
  }
}
