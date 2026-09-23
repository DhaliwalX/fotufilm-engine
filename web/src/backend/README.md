# Editor backends

The Spectrum editor uses one React tree and one versioned image-backend contract.
Browser processing lives behind `browser.js`; a Mac host can provide native
services through `window.fotufilmNative` **before `main.jsx` executes**. Selection
happens once per editor mount, not per operation. Reload to change backends.

The browser adapter is implemented. The `macos/` JavaScript facade defines the
transport boundary for a native host; host packaging is developed separately.
`native.js` validates and binds host-supplied services. Missing/incompatible bridges
fail visibly and never silently initialize the browser engine.

```text
Spectrum components / edit history / debounced viewport requests
                            |
                      BackendContext
                            |
             +--------------+---------------+
             |                              |
        browser.js                      native.js
  WASM + WebGPU / workers           host JavaScript bridge
                                            |
                                   Swift / Halide / Metal
```

## Version 1 contract

Factories, `releaseImage`, `outputColorSpace`, lens `snapshot` and `subscribe` are
synchronous. Other operations return promises. `contract.js` lists required
methods and checks the interface version. Callbacks and `AbortSignal` belong to the
JavaScript facade: a native transport must translate them to request IDs, progress
events and cancellation messages, rather than attempting to serialize functions.

| Method | Input and result |
| --- | --- |
| `createSession()` | A session with `render(request)`, `stages(stock, medium, halationModel, digitalReference)`, synchronous `dispose()`, and assignable `onRendererReady` callback. |
| `prepare(session, report)` | Initialize processing; report `{value: 0…100, label, done}`. Resolve after preparation and report `done: true`. |
| `loadStocks()` | Film entries matching the existing catalogue: `id`, `name`, `media`, `defaultMedium`, `available`, `profile`, `nativeFormat`, and any fixed-profile restrictions. |
| `importMedia(file, options)` | Browser `File`; options `{signal, onProgress(text), negative}`. Resolve `{image, url}`. `negative` requests an unadjusted scan suitable for inversion. |
| `releaseImage(image)` | Release the caller's image lease, including video resources. Idempotent, non-throwing, safe while previously submitted work completes. |
| `analyseNegative(image, monochrome, onProgress?)` | Return the negative-conversion plan, including `weak`. The plan is otherwise opaque to the UI. |
| `convertNegative(image, plan, options)` | Options `{signal, maxEdge?, onProgress({progress})}`. Return `{image, backend}` with a **new owned image**, preserving full source precision. |
| `makePreview(image, options)` | Decorate that same owned image with `src`; return `{image, url}`. Do not create a second image lease. |
| `createHistogram()` | `{analyse(renderResult, {signal}), dispose()}`. Return the histogram schema below. |
| `autoAdjust(request)` | `{image, edit, session, signal, onProgress(text)}` → `{ev, highlights, shadows}`. |
| `planPrintFrame(edit, width, height, onProgress?)` | Existing print-frame plan, including `configuration` and `placement: {size, image}`. |
| `resolveLensPlan(image, lens, onProgress?)` | Existing lens plan for inspector diagnostics, including profile/note/correction-table information. |
| `sampleScene(renderResult, point)` | Normalized photograph coordinates `[x,y]` → scene-linear Rec.2020 `[r,g,b]`, or `null`. May resolve asynchronously; the editor discards obsolete samples. |
| `outputColorSpace()` | `"srgb"` or `"display-p3"` for ordinary still export. TIFF retains the editor's 16-bit Display P3 contract; video uses sRGB/Rec.709. |
| `exportImage(request)` | `{session,image,edit,stock,maxEdge,type,quality,filename,onProgress(text)}`. Resolve only after saving; reject cancellation with `AbortError`. Encoding and destination selection belong to the backend. |
| `exportVideo(request)` | Same image/edit/session fields plus `{format,quality,filename,signal,onProgress({progress,frames,finalizing})}`. Return `{filename,url?,dispose()}`; `dispose` releases temporary download resources, never deletes the accepted saved file. |
| `lenses` | `{snapshot(),subscribe(listener),load(),import(file,onProgress?),remove()}`. Snapshot is a stable object `{profiles,revision,loaded,error?}` until changed. Subscribe returns an unsubscribe function. Import resolves the installed profile count; remove clears the installed catalogue. Publish a new snapshot on changes or load failure. |

### Images, previews and ownership

An image is a JavaScript descriptor with `naturalWidth`, `naturalHeight`, and a
bounded display-preview `src`. Native descriptors can carry an opaque `handle`;
full-resolution pixel arrays are not required in React or across the bridge.
Optional source metadata uses the existing shape: `raw: {profile?}`, `linear`,
`hdr`, `standardImage`, `exr`, and `lensMetadata`. These describe the input and
control availability; native descriptors must not expose huge pixel buffers here.
Video descriptors also include `video: {start,duration,playbackUrl}` for the shared
transport controls. Provide a webview-playable proxy URL if the original codec
cannot be played by its media element; processing and export remain native.

Each successful import/conversion grants one image lease. The library releases it
on removal/unmount; a negative dialog releases cancelled, failed and superseded
provisional images. `image-scope.js` handles results arriving after cancellation.
A completed positive transfers its lease to the library. `url`/`src` are blob URLs
created by the JavaScript facade and revoked by the UI. Sessions retain any native
input references needed by in-flight work even after the caller releases its lease.
The backend releases its own caches and GPU allocations when the session closes.

### Rendering and analysis

`render(request)` takes `{image, edit, stock, maxEdge, videoTime?, viewport?,
stage?, difference?, cropMode?, showMask?, background?, comparison?, purpose?,
bitDepth?, stale?, onProgress?}`. Use the existing saved-edit schema unchanged.
`maxEdge: Infinity` means original size; encode it explicitly in a JSON transport.
A viewport is `{width,height,region:{x,y,width,height}}` from `viewport.js`: the
virtual full-image size and its visible subrectangle, both in output pixels. Render only that area at that size,
while preserving full-image coordinates for grain and spatial effects. The UI
keeps its existing 300 ms debounce and replaces a tile only after decoding it.

Return `{blob, original, width, height, colorSpace, backend, elapsed,
renderMilliseconds, framePlan?, viewport?}`. `blob` and `original` are display-ready
image Blobs; previews/thumbs never require a DOM canvas or native pixel buffer.
`elapsed`/`renderMilliseconds` are milliseconds. Keep native sampling state behind
an opaque result token when needed. The browser adapter can retain `sceneSource`
instead. Session disposal must reclaim these retained sampling/cache resources.

Sessions serialize conflicting work, prioritize interactive work over thumbnails,
and skip obsolete requests (`stale()` or disposed session → `null`). Closing a
session prevents further work and notifications. Render/analysis rejection must
be an `Error` with a readable message. Cancellation is `AbortError`; do not resolve
an old job as the result of a newer one.

Histogram analysis returns `{bins, luma, chroma, oklab, count}`: RGB has three
256-bin channels, luma one, chroma two, and OKLab three. Match `histogram-model.js`
and its tests: these counts describe the encoded display preview and its colour
space, not unbounded scene-linear pixels. This keeps graph modes and clipping
readouts identical between backends.

## Verification

`backend.test.js` checks versioning, binding, resource ownership and the static UI
dependency boundary. `backend-histogram.test.js` exercises cancellation/error
races. `native-backend.spec.js` and `native-resources.spec.js` supply a test-only native double and drive the
real editor without fetching browser engine assets. It is a contract integration
test, **not evidence of native rendering performance or image-quality parity**.
When implementing a real host, run the same UI suite against it and compare
representative CPU/Metal/WebGPU output before shipping.
