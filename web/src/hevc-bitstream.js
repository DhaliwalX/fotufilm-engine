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
export function annexB(nals) {
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
export function packetBytes(data, lengthSize) {
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
