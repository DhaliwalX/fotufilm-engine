const MAX_PACK_BYTES = 32 * 1024 * 1024
const digest = async (data) => new Uint8Array(await crypto.subtle.digest('SHA-256', data))
const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i])

// The native exporter seals every configuration, cube and size rung. The browser
// reconstructs those exact bytes; it does not approximate a medium with a grade.
export async function applyMediumDelta(base, compressed) {
  const reader = new Blob([compressed])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
    .getReader()
  const chunks = []
  let length = 0
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      length += value.length
      if (length > MAX_PACK_BYTES + 80)
        throw new Error('Output medium exceeds the pack size limit.')
      chunks.push(value)
    }
  } finally {
    await reader.cancel()
  }
  const bytes = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.length
  }
  if (length < 80) throw new Error('Incomplete output medium.')
  const header = new DataView(bytes.buffer)
  if (String.fromCharCode(...bytes.subarray(0, 4)) !== 'FMED' || header.getUint32(4, true) !== 1)
    throw new Error('Unsupported output medium format.')
  const size = header.getUint32(12, true)
  if (
    base.byteLength !== header.getUint32(8, true) ||
    size !== length - 80 ||
    !equal(await digest(base), bytes.subarray(16, 48))
  )
    throw new Error('Output medium and film pack do not match. Rebuild the browser packs together.')
  const original = new Uint8Array(base),
    result = bytes.slice(80)
  for (let i = 0; i < size; i++) result[i] ^= original[i] || 0
  if (!equal(await digest(result), bytes.subarray(48, 80)))
    throw new Error('Output medium is corrupt.')
  return result.buffer
}

export async function loadMediumBytes(base, url) {
  const response = await fetch(url)
  if (!response.ok) throw new Error('The selected output medium could not be loaded.')
  return applyMediumDelta(base, await response.arrayBuffer())
}
