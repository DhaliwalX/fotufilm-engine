// Classic worker (the HEVC decoder loads with importScripts): a HEIC's primary image, or its
// thumbnail, as interleaved scene-linear Rec. 2020 RGBA in its displayed orientation.
import { heifImage, heifOrientation, heifCrop } from './heif.js'
import { heifColorSpace, iccToRec2020, applyICC } from './heif-color.js'
import { hevcConfiguration, packetBytes } from './hevc-bitstream.js'
import { openHEVCDecoder } from './hevc-wasm.js'
import { decodeVideoPlanes } from './video-color.js'
import { orientedPixel } from './hdr-color.js'

const REC2020_TO_SRGB = [1.660491, -0.587641, -0.07285, -0.12455, 1.1329, -0.008349,
  -0.018151, -0.100579, 1.11873]

self.onmessage = async ({ data: { bytes, factoryUrl, wasmUrl, thumbnail = 0 } }) => {
  try {
    const image = heifImage(new Uint8Array(bytes), { thumbnail: thumbnail > 0 })
    const { grid, tiles } = image
    if (grid.width * grid.height > 120000000)
      throw new Error('Images above 120 megapixels are not supported.')
    const decoder = await openHEVCDecoder({ factoryUrl, wasmUrl })
    const pictures = []
    for (const [index, tile] of tiles.entries()) {
      if (index % 8 === 0)
        self.postMessage({ status: `Decoding HEIC · ${Math.round((index * 100) / tiles.length)}%` })
      const { lengthSize, parameters } = hevcConfiguration(tile.config)
      const data = packetBytes(tile.data, lengthSize)
      const stream = new Uint8Array(parameters.length + data.length)
      stream.set(parameters)
      stream.set(data, parameters.length)
      pictures.push(...decoder.feed(stream))
    }
    pictures.push(...decoder.flush())
    const { width: tw, height: th, depth } = pictures[0] ?? {}
    if (pictures.length !== tiles.length ||
        pictures.some((p) => p.width !== tw || p.height !== th || p.depth !== depth) ||
        tw * grid.columns < grid.width || th * grid.rows < grid.height ||
        (grid.columns > 1 && tw % 2) || (grid.rows > 1 && th % 2))
      throw new Error('This HEIC file could not be decoded.')

    const icc = image.icc && iccToRec2020(image.icc)
    const colorSpace = heifColorSpace(image.nclx, { icc: !!icc })
    const crop = heifCrop(image.transforms, grid.width, grid.height)
    const orientation = heifOrientation(image.transforms)
    const swapped = orientation >= 5
    const width = swapped ? crop.height : crop.width, height = swapped ? crop.width : crop.height
    const pixels = new Float32Array(width * height * 4)
    const bytesPerSample = depth > 8 ? 2 : 1
    const W = grid.width, cw = Math.ceil(W / 2)

    // One row of tiles at a time, so the converter's frame limit and memory stay small.
    for (let row = 0; row < grid.rows; row++) {
      const top = row * th, bandHeight = Math.min(th, grid.height - top)
      if (top + bandHeight <= crop.y || top >= crop.y + crop.height) continue
      self.postMessage({ status: `Converting HEIC to scene-linear color · ${Math.round((row * 100) / grid.rows)}%` })
      const ch = Math.ceil(bandHeight / 2)
      const sizes = [[W, bandHeight], [cw, ch], [cw, ch]]
      const layout = [], planeOffsets = []
      let total = 0
      for (const [w, h] of sizes) {
        layout.push({ offset: total, stride: w * bytesPerSample })
        planeOffsets.push(total)
        total += w * h * bytesPerSample
      }
      const band = new Uint8Array(total)
      for (let column = 0; column < grid.columns; column++) {
        const picture = pictures[row * grid.columns + column]
        for (let plane = 0; plane < 3; plane++) {
          const tileWidth = plane ? Math.ceil(tw / 2) : tw
          const x0 = column * tileWidth
          const [w, h] = sizes[plane]
          const span = Math.min(tileWidth, w - x0) * bytesPerSample
          if (span <= 0) continue
          const source = picture.layout[plane]
          for (let y = 0; y < h; y++) {
            const from = source.offset + y * source.stride
            band.set(picture.data.subarray(from, from + span),
              planeOffsets[plane] + y * layout[plane].stride + x0 * bytesPerSample)
          }
        }
      }
      const linear = decodeVideoPlanes({
        data: band, layout, format: depth > 8 ? 'I420P10' : 'I420',
        width: W, height: bandHeight, colorSpace,
      }, 'standard')
      if (icc) applyICC(linear, icc)
      const y0 = Math.max(top, crop.y), y1 = Math.min(top + bandHeight, crop.y + crop.height)
      for (let y = y0; y < y1; y++)
        for (let x = crop.x; x < crop.x + crop.width; x++) {
          const input = ((y - top) * W + x) * 4
          const [ox, oy] = orientedPixel(x - crop.x, y - crop.y, crop.width, crop.height, orientation)
          const output = (oy * width + ox) * 4
          for (let c = 0; c < 3; c++)
            pixels[output + c] = Number.isFinite(linear[input + c]) ? linear[input + c] : 0
          pixels[output + 3] = 1
        }
    }
    if (thumbnail > 0) {
      const result = thumbnailPixels(pixels, width, height, thumbnail)
      self.postMessage({ result }, [result.pixels.buffer])
    } else
      self.postMessage({ result: { pixels, width, height, bitDepth: depth } }, [pixels.buffer])
  } catch (error) {
    self.postMessage({ error: error.message || 'The HEIC decoder could not run.' })
  }
}

// A small sRGB picture for the strip: nearest samples, clipped to the display range.
function thumbnailPixels(pixels, width, height, maxEdge) {
  const scale = Math.min(1, maxEdge / Math.max(width, height))
  const w = Math.max(1, Math.round(width * scale)), h = Math.max(1, Math.round(height * scale))
  const out = new Uint8ClampedArray(w * h * 4), m = REC2020_TO_SRGB
  const encode = (v) => {
    v = Math.max(0, Math.min(1, v))
    return 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055)
  }
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const i = (Math.min(height - 1, Math.floor((y + 0.5) / scale)) * width +
        Math.min(width - 1, Math.floor((x + 0.5) / scale))) * 4
      const r = pixels[i], g = pixels[i + 1], b = pixels[i + 2], o = (y * w + x) * 4
      out[o] = encode(m[0] * r + m[1] * g + m[2] * b)
      out[o + 1] = encode(m[3] * r + m[4] * g + m[5] * b)
      out[o + 2] = encode(m[6] * r + m[7] * g + m[8] * b)
      out[o + 3] = 255
    }
  return { pixels: out, width: w, height: h }
}
