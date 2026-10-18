// Classic worker for mediabunny's software HEVC decoder (hevc-decoder.js). Only encoded packets
// and copied YUV planes cross this boundary.
import { openHEVCDecoder } from './hevc-wasm.js'

let decoder
self.onmessage = async ({ data: message }) => {
  try {
    let output = []
    if (message.type === 'init') decoder = await openHEVCDecoder(message)
    else if (message.type === 'decode')
      output = decoder.feed(new Uint8Array(message.data))
    else if (message.type === 'flush') output = decoder.flush()
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
