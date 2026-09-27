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
| `convertNegative(image, plan, options)` | Options `{signal, maxEdge?, contrast?, onProgress({progress})}`. Return `{image, backend}` with a **new owned image**, preserving full source precision. `contrast` is stops of mid-grey slope from the plan's automatic contrast (0 keeps it); honour it only when the backend sets `negativeContrast: true`. |
| `suggestNegativeFilms(image)` | Optional. Return up to three `{films: [{id, name}], likelihood}` for the installed films whose clear base the scan's looks like, most likely first; films a scan cannot tell apart share one entry. Suggestions, not an identification. |
| `negativeScans` | Optional. The negative-scan session the apps have (below); without it the editor keeps the automatic import above. |
| `subjectSelection` | Optional `true` when the backend detects subjects: an edit's `selective.kind` may then be `"subject"`, selecting the subject under `selective.point` (every subject when the point is on the background), feathered by `softness`. |
| `previewBudget` | Optional `{settleMs?, initialInteractiveEdge?, minInteractiveEdge?, maxInteractiveEdge?, detailDelayMs?}`: how the editor paces previews while an edit moves (`web/src/preview-budget.js` holds the browser defaults). A backend that develops a full preview within a frame or two raises the edge and shortens the settle. |
| `makePreview(image, options)` | Decorate that same owned image with `src`; return `{image, url}`. Do not create a second image lease. |
| `createHistogram()` | `{analyse(renderResult, {signal}), dispose()}`. Return the histogram schema below. |
| `autoAdjust(request)` | `{image, edit, session, signal, onProgress(text)}` → `{ev, highlights, shadows}`. |
| `planPrintFrame(edit, width, height, onProgress?)` | Existing print-frame plan, including `configuration` and `placement: {size, image}`. |
| `resolveLensPlan(image, lens, onProgress?)` | Existing lens plan for inspector diagnostics, including profile/note/correction-table information. |
| `sampleScene(renderResult, point)` | Normalized photograph coordinates `[x,y]` → scene-linear Rec.2020 `[r,g,b]`, or `null`. May resolve asynchronously; the editor discards obsolete samples. |
| `outputColorSpace()` | `"srgb"` or `"display-p3"` for ordinary still export. TIFF retains the editor's 16-bit Display P3 contract; video uses sRGB/Rec.709. |
| `exportImage(request)` | `{session,image,edit,stock,maxEdge,type,quality,metadata?,hdr?,filename,onProgress(text)}`. Resolve only after saving; reject cancellation with `AbortError`. Encoding and destination selection belong to the backend. `metadata` and `hdr` apply only where `exportOptions` offers them. |
| `exportImageCancels` | Optional `true` when `exportImage` stops on `request.signal` (the editor then offers Cancel during a still export). |
| `exportOriginal(image)` | Optional (Export Original). Copies the camera RAW an image descriptor's `original: {name}` names, to a destination the backend chooses; no edit or size applies. Only offered for images that carry `original`. |
| `exportOptions(request)` | Optional. `{image,edit,stock,maxEdge}` → `{metadata: [policy], hdr}`: the source-metadata policies the backend writes (`preserve`, `preserveWithoutLocation`, `strip`) and whether a HEIC of this edit can be HDR (the film delivers light above display white and no print frame is set). |
| `suggestFilm(request)` | Optional (Choose Film Per Photo). `{image,edit,photoID,films?}` → `{best,ordered:[{id,name,score}],summary}`: every installed film (or the named `films`) developed at the scoring size and ranked for the photograph, weighted by what this person has chosen before. The editor applies `best` to a newly opened photograph when the `autoFilm` setting is on. |
| `recordFilmChoice(photoID, film)` / `forgetFilmChoices()` | Optional, beside `suggestFilm`. Record the film a photograph settled on, against its last ranking, so later rankings learn; forget returns to the hand-set weights. The backend keeps the history on the device. |
| `plugins` | Optional. The plug-ins for other editors the host installs, `[{id, name}]` (Fotufilm Desktop on macOS: `resolve` DaVinci Resolve, `finalCut` Final Cut Pro), from its capabilities. With it come `pluginStatus()`, `installPlugin(id)` and `revealPlugin(id)`; the editor shows a Plug-ins dialog and the host's Plugins menu runs `installPlugin:<id>` / `revealPlugin:<id>` through `useNativeCommands.js`. |
| `pluginStatus()` | Beside `plugins`. `[{id, name, state, bundledVersion?, installedVersion?, hostInstalled, location, note?}]`: `state` is `notBundled` (this build lacks it), `notInstalled`, `outdated` (installed from another build, newer or older) or `installed`; `hostInstalled` whether the editor it is for is on the computer; `note` what to know before installing. |
| `installPlugin(id)` / `revealPlugin(id)` | Beside `plugins`. Install (or reinstall) this build's plug-in, resolving `{message, plugins}` — what to tell the person and every plug-in's new state — after the copy and any registration; reject with a readable message. Reveal shows the installed plug-in in the platform's file manager and rejects when it is not installed. |
| `importPath(path, options)` | Optional, for hosts with a file system. Opens a file the host chose (open panel, Finder, menu) in place; options as `importMedia`. Resolve `{image, url, identity?}`: `identity` is what the file's last edit is kept under (below). |
| `loadEdit(key)` / `saveEdit(key, text)` | Optional pair, for a host that keeps edits itself. Load resolves the text kept under `key` or `null`; save keeps `text`, or forgets the key when it is `null`. Without them the editor keeps edits in the photo library's IndexedDB records on the device (a desktop host's persistent profile). |
| `exportVideo(request)` | Same image/edit/session fields plus `{format,quality,filename,signal,onProgress({progress,frames,finalizing})}`. Return `{filename,url?,dispose()}`; `dispose` releases temporary download resources, never deletes the accepted saved file. |
| `videoExportTypes` | Optional. The movie formats a native encoder writes, `[{id, label, extension, type, quality, bits, colorSpace}]`, replacing the browser's MP4/WebM list; `quality: false` hides the quality choice (ProRes). `format` in `exportVideo` is one of the ids. |
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
cannot be played by its media element; processing and export remain native. The
media element is only the clock and the sound: every frame shown is a render at
`videoTime`. A native host whose web view lacks the movie's codecs (Fotufilm
Desktop's Chromium) answers `importVideo`/`importPath` with the sound as a WAV
(`playback`, `playbackType`), silent when the movie is, and the page plays that.

Each successful import/conversion grants one image lease. The library releases it
on removal/unmount; a negative dialog releases cancelled, failed and superseded
provisional images. `image-scope.js` handles results arriving after cancellation.
A completed positive transfers its lease to the library. `url`/`src` are blob URLs
created by the JavaScript facade and revoked by the UI. Sessions retain any native
input references needed by in-flight work even after the caller releases its lease.
The backend releases its own caches and GPU allocations when the session closes.

### Negative scans

A backend with `negativeScans` prints scanned negatives itself, as the Mac and iPad apps'
session does (`web/src/negative-scan/`). The scan opens once and stays unchanged; everything the
person sets is a `NegativeScanRecipe` (`Sources/FotufilmEditModel/NegativeScanRecipe.swift`), sent
whole with each call in the recipe's own JSON form: `conversion` (`automatic` or `film`),
`monochrome`, `stockID`, `border` and `borderArea`, `paperID`, `exposure`, `warmth`, `tint`,
`contrast`, `highlights`, `shadows`, `lightFrameID`, `quarterTurns`, `mirrored`, `straighten` and
`crop` (`{x, y, width, height}`, unit, top left, in the oriented and straightened picture).

| Member | Input and result |
| --- | --- |
| `encoding` | `true` when a scan's samples may be read as linear light instead of through its file's colour profile (never for camera RAW). |
| `open(file, {linearSamples?, signal?})` | A `File` (or `{path}` the host chose). Resolves `{handle, naturalWidth, naturalHeight, raw, films: [{id, name, monochrome, papers: [{id, name}]}], suggestions, lightFrames: [{id, name}], recipe}`: the films a scan can be read as (no slides) with the receivers each prints on, `suggestNegativeFilms`' readings, and the starting recipe. |
| `render(handle, recipe, {maxEdge, cropped?, negative?, signal?})` | The print, or with `negative` the scan as the recipe frames it; cropped unless `cropped` is false. Resolves `{blob, width, height, colorSpace, renderMilliseconds}`. |
| `sampleBorder(handle, recipe, area)` | `area` a unit rectangle of the whole oriented negative (as `render` shows it uncropped). Resolves `{border, borderArea}` for the recipe, or rejects when the area is not clear film. |
| `detectFrame(handle, recipe)` | The picture between rebate and holder as a crop, or `null`. |
| `commit(handle, recipe, {signal?})` | The full-resolution print as a **new owned image** `{image, url}`, which the editor opens with no film. |
| `lightFrames()` / `addLightFrame(file)` / `removeLightFrame(id)` | Photographs of the bare light source, kept on the device, that a recipe's `lightFrameID` divides out. |
| `release(handle)` | Closes the scan. |

### Kept edits and the Edit History

A photograph opened again starts from the edit it was left with, as the Mac app's shelf does
(`web/src/saved-edits.js`, `web/src/editor/useSavedEdits.js`). Each is kept as the text Save
Edits writes, under a key: a photo-library photo's library key, otherwise the file's identity. A
still is known by the SHA-256 of its bytes (`sha256:<hex>`, the Mac app's key), a movie — or any
file on a host without a digest — by `file:<name>|<size>|<modified ms>`. The editor computes the
identity of a `File` it was handed; a host that opens paths answers it with `importPath`, in the
same form, so a photograph dropped on the window and the same one opened from a menu share their
edit. A second open of a photograph already open shows it rather than opening a copy.

Undo, Redo and the Edit History name each step after what it changed, with the Mac app's names
(`web/src/edit-history.js`): "Undo Lens Correction", a film's name for a change of film. The
history reducer's `goTo` action jumps to any step and keeps the timeline whole.

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
