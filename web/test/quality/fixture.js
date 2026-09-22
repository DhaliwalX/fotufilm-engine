// A version-1 pack with the exact configuration used for this frame. This is a
// development fixture for the native benchmark, never part of the site bundle.
export function nativeFramePack(developer) {
  const { module, pack } = developer
  const count = pack.configuration.length
  const bytes = new Uint8Array(40 + (count + pack.exposure.length * 3) * 4)
  bytes.set(new TextEncoder().encode('FSWP'))
  const header = new DataView(bytes.buffer)
  ;[
    1,
    developer.width,
    developer.height,
    developer.featureMask,
    developer.seed,
    count,
    33,
    pack.exposure.length,
    1,
  ].forEach((value, i) => header.setUint32(4 + i * 4, value, true))
  const values = new Float32Array(bytes.buffer, 40)
  let offset = 0
  const configuration = module.HEAPF32.subarray(
    developer.configPtr / 4,
    developer.configPtr / 4 + count,
  )
  for (const data of [configuration, pack.exposure, pack.film, pack.paper]) {
    values.set(data, offset)
    offset += data.length
  }
  let binary = ''
  for (let i = 0; i < bytes.length; i += 4096)
    binary += String.fromCharCode(...bytes.subarray(i, i + 4096))
  return btoa(binary)
}
