// Project-authored uncompressed DNG. No camera photos or calibration data are fixtures.
export function makeDNG({ width = 320, height = 192, orientation = 1, mosaic = true } = {}) {
  const channels = mosaic ? 1 : 3
  const tags = []
  const add = (tag, type, values) => tags.push({ tag, type, values })
  add(254, 4, [0])
  add(256, 4, [width])
  add(257, 4, [height])
  add(258, 3, Array(channels).fill(16))
  add(259, 3, [1])
  add(262, 3, [mosaic ? 32803 : 34892])
  add(271, 2, 'Fotufilm')
  add(272, 2, 'Synthetic DNG')
  add(273, 4, [0])
  add(274, 3, [orientation])
  add(277, 3, [channels])
  add(278, 4, [height])
  add(279, 4, [width * height * channels * 2])
  add(284, 3, [1])
  if (mosaic) {
    add(33421, 3, [2, 2])
    add(33422, 1, [0, 1, 1, 2])
  }
  add(50706, 1, [1, 4, 0, 0])
  add(50707, 1, [1, 1, 0, 0])
  add(50708, 2, 'Fotufilm Synthetic DNG')
  add(50714, 5, [512])
  add(50717, 4, [65535])
  add(
    50721,
    10,
    [
      3.2404542, -1.5371385, -0.4985314, -0.969266, 1.8760108, 0.041556, 0.0556434, -0.2040259,
      1.0572252,
    ],
  )
  add(50728, 5, [1, 1, 1])
  add(50778, 3, [21])
  tags.sort((a, b) => a.tag - b.tag)
  const sizes = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 10: 8 }
  let next = 8 + 2 + tags.length * 12 + 4
  for (const entry of tags) {
    entry.count = entry.type === 2 ? entry.values.length + 1 : entry.values.length
    entry.length = entry.count * sizes[entry.type]
    if (entry.length > 4) {
      entry.offset = next
      next += (entry.length + 3) & ~3
    }
  }
  tags.find((entry) => entry.tag === 273).values = [next]
  const bytes = new Uint8Array(next + width * height * channels * 2)
  const view = new DataView(bytes.buffer)
  view.setUint16(0, 0x4949, true)
  view.setUint16(2, 42, true)
  view.setUint32(4, 8, true)
  view.setUint16(8, tags.length, true)
  tags.forEach((entry, i) => {
    const at = 10 + i * 12
    view.setUint16(at, entry.tag, true)
    view.setUint16(at + 2, entry.type, true)
    view.setUint32(at + 4, entry.count, true)
    const dest = entry.offset || at + 8
    if (entry.offset) view.setUint32(at + 8, entry.offset, true)
    if (entry.type === 2) bytes.set(new TextEncoder().encode(entry.values), dest)
    else
      entry.values.forEach((value, j) => {
        const p = dest + j * sizes[entry.type]
        if (entry.type === 1) view.setUint8(p, value)
        else if (entry.type === 3) view.setUint16(p, value, true)
        else if (entry.type === 4) view.setUint32(p, value, true)
        else {
          view.setInt32(p, Math.round(value * 1000000), true)
          view.setInt32(p + 4, 1000000, true)
        }
      })
  })
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const color = mosaic ? [0, 1, 1, 2][(y % 2) * 2 + (x % 2)] : 0
      for (let c = 0; c < channels; c++) {
        const channel = mosaic ? color : c
        // Dark linear ramp with enough codes to expose an accidental RGBA8 intermediate.
        const value = 512 + 1200 + x * 11 + y * 7 + [100, 40, 0][channel]
        view.setUint16(next + ((y * width + x) * channels + c) * 2, Math.min(value, 65000), true)
      }
    }
  return bytes
}
