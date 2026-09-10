import { decodeEXR } from './exr-decode.js'

self.onmessage = ({ data }) => {
  try {
    const result = decodeEXR(data.bytes)
    self.postMessage(result, [result.pixels.buffer])
  } catch (error) {
    self.postMessage({ error: error.message })
  }
}
