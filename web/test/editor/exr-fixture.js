// Tiny original OpenEXR fixture, independent of the decoder. RGB float32 scanlines.
export function exrFixture(
  pixels,
  width,
  height,
  chromaticities = [0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329],
) {
  const bytes = [],
    text = (value) => {
      bytes.push(...new TextEncoder().encode(value), 0)
    }
  const integer = (value) => {
    const b = new Uint8Array(4)
    new DataView(b.buffer).setInt32(0, value, true)
    bytes.push(...b)
  }
  const float = (value) => {
    const b = new Uint8Array(4)
    new DataView(b.buffer).setFloat32(0, value, true)
    bytes.push(...b)
  }
  const attribute = (name, kind, length, write) => {
    text(name)
    text(kind)
    integer(length)
    write()
  }
  integer(20000630)
  integer(2)
  attribute('channels', 'chlist', 55, () => {
    for (const c of 'BGR') {
      text(c)
      integer(2)
      integer(0)
      integer(1)
      integer(1)
    }
    bytes.push(0)
  })
  attribute('compression', 'compression', 1, () => bytes.push(0))
  for (const name of ['dataWindow', 'displayWindow'])
    attribute(name, 'box2i', 16, () => [0, 0, width - 1, height - 1].forEach(integer))
  attribute('lineOrder', 'lineOrder', 1, () => bytes.push(0))
  attribute('pixelAspectRatio', 'float', 4, () => float(1))
  attribute('screenWindowCenter', 'v2f', 8, () => {
    float(0)
    float(0)
  })
  attribute('screenWindowWidth', 'float', 4, () => float(1))
  if (chromaticities)
    attribute('chromaticities', 'chromaticities', 32, () => chromaticities.forEach(float))
  bytes.push(0)
  const start = bytes.length + height * 8
  for (let y = 0; y < height; y++) {
    integer(start + y * (width * 12 + 8))
    integer(0)
  }
  for (let y = 0; y < height; y++) {
    integer(y)
    integer(width * 12)
    for (const c of [2, 1, 0])
      for (let x = 0; x < width; x++) float(pixels[(y * width + x) * 3 + c])
  }
  return new Uint8Array(bytes).buffer
}
