import factoryUrl from '../node_modules/@hevcjs/core/dist/wasm/hevc-decode.js?url'
import wasmUrl from '../node_modules/@hevcjs/core/dist/wasm/hevc-decode.wasm?url'

// Where a worker loads the pinned software HEVC decoder from (`openHEVCDecoder`).
export const hevcAssets = () => ({
  factoryUrl: new URL(factoryUrl, location.href).href,
  wasmUrl: new URL(wasmUrl, location.href).href,
})
