# Editor backends

The Spectrum editor uses one React tree and one versioned image-backend contract.
Browser processing lives behind `browser.js`; a native host can provide native
services through `window.fotufilmNative` **before `main.jsx` executes**. Selection
happens once per editor mount, not per operation. Reload to change backends.

The browser adapter is implemented. The `desktop/` JavaScript facade defines the
transport boundary for a native host (Fotufilm Desktop, the same on every platform); host
packaging is developed separately. The transport's `capabilities.platform` (`macos`, `linux`,
`windows`) names the host's platform, which `main.jsx` sets as `data-native-host` for its window
chrome.
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
| `loadStocks()` | Film entries matching the existing catalogue: `id`, `name`, `media`, `defaultMedium`, `available`, `profile`, `nativeFormat`, `readsNegative`, and any fixed-profile restrictions. |
| `importMedia(file, options)` | Browser `File`; options `{signal, onProgress(text), negative}`. Resolve `{image, url}`. `negative` opens an unadjusted scan as a negative document (below). |
| `releaseImage(image)` | Release the caller's image lease, including video resources. Idempotent, non-throwing, safe while previously submitted work completes. |
| `negativeScans` | Optional. Scanned negatives read as a film and printed by the backend (below); without it the editor does not offer them. |
| `longEdgeOfCrop` | Optional `true` when every `maxEdge` bounds the long edge of the cropped picture it delivers, as the Mac app sizes previews and exports, rather than of the whole upright picture; export sizes are then of the cropped picture. |
| `subjectSelection` | Optional `true` when the backend detects subjects: an edit's `selective.kind` may then be `"subject"`, selecting the subject under `selective.point` (every subject when the point is on the background), feathered by `softness`. |
| `previewBudget` | Optional `{settleMs?, initialInteractiveEdge?, minInteractiveEdge?, maxInteractiveEdge?, detailDelayMs?}`: how the editor paces previews while an edit moves (`web/src/preview-budget.js` holds the browser defaults). A backend that develops a full preview within a frame or two raises the edge and shortens the settle. |
| `playbackQuality` | Optional boolean. The editor offers Playback Quality (Draft 640, Standard 1280, Fine 1920, Full · 4K 3840 px long edge) and asks for playing movie frames at that `maxEdge`; a paused frame develops at full detail. |
| `updates` | Optional `{check, status, install, cancel, notes}`, each resolving at once to `{state, current, version?, release?, notes?, bytes?, total?, message?}`: Check for Updates on the host's own release feed. `state` is `idle`, `checking`, `current`, `available`, `failed`, `downloading`, `opened` or `downloadFailed`; the editor polls `status` while a check or download runs, and the host verifies the installer's SHA-256 before opening it. |
| `createHistogram()` | `{analyse(renderResult, {signal}), dispose()}`. Return the histogram schema below. |
| `autoAdjust(request)` | `{image, edit, session, signal, onProgress(text)}` → `{ev, highlights, shadows}`. |
| `planPrintFrame(edit, width, height, onProgress?)` | Existing print-frame plan, including `configuration` and `placement: {size, image}`. |
| `resolveLensPlan(image, lens, onProgress?)` | Existing lens plan for inspector diagnostics, including profile/note/correction-table information. |
| `sampleScene(renderResult, point)` | Normalized photograph coordinates `[x,y]` → scene-linear Rec.2020 `[r,g,b]`, or `null`. May resolve asynchronously; the editor discards obsolete samples. |
| `outputColorSpace()` | `"srgb"` or `"display-p3"` for ordinary still export. TIFF retains the editor's 16-bit Display P3 contract; video uses sRGB/Rec.709. |
| `exportImage(request)` | `{session,image,edit,stock,maxEdge,type,quality,metadata?,hdr?,filename,onProgress(text)}`. Resolve only after saving, with `{filename, path?}` where the backend saved to disk; reject cancellation with `AbortError`. Encoding and destination selection belong to the backend. `metadata` and `hdr` apply only where `exportOptions` offers them. |
| `openExport(path, {reveal})` | Optional. Opens a file an export saved (the `path` an export resolved with) in the system's app for it, or with `reveal` shows it in the file manager, which `revealExportLabel` names ("Show in Finder"). |
| `exportImageCancels` | Optional `true` when `exportImage` stops on `request.signal` (the editor then offers Cancel during a still export). |
| `exportImages(request)` | Optional (Export All). `{items:[{image?, path?, name, filename, edit, stock}], size, type, quality, metadata?, hdr?, signal, onProgress({progress, done, total, name?, current?})}`: every item into one folder the backend asks for, each with its own edit. An item is an open photograph (`image`) or a file not opened yet (`path`, decoded by the backend). `size` is an export size id (`"full"`, a fraction such as `"0.75"`, or a long edge in pixels) of each cropped picture; one past the memory limit gives way to the largest that fits. Resolve `{directory, written:[{filename, path, width, height}], failed:[{name, error}], reduced:[name]}`; files never overwrite one already there. Reject cancellation with `AbortError`, keeping what was written. |
| `fileIdentities(paths)` | Optional, beside `exportImages`, as is `hdrExport` (`true` when a HEIC may be HDR where its film delivers it). The `identity` `importPath` would answer for each path (or `null`), so the kept edits of photographs not opened yet are found. |
| `exportOriginal(image)` | Optional (Export Original). Copies the camera RAW an image descriptor's `original: {name}` names, to a destination the backend chooses; no edit or size applies. Only offered for images that carry `original`. |
| `exportOptions(request)` | Optional. `{image,edit,stock,maxEdge,sizes?,photoQuality?}` → `{metadata: [policy], hdr, unavailable?}`: the source-metadata policies the backend writes (`preserve`, `preserveWithoutLocation`, `strip`), whether a HEIC of this edit can be HDR (the film delivers light above display white and no print frame is set), and the ids of `sizes` (`{id,width,height}`, pixels of the cropped picture) too large to develop within the backend's memory limit. |
| `suggestFilm(request)` | Optional (Choose Film Per Photo). `{image,edit,photoID,films?}` → `{best,ordered:[{id,name,score}],summary}`: every installed film (or the named `films`) developed at the scoring size and ranked for the photograph, weighted by what this person has chosen before. The editor applies `best` to a newly opened photograph when the `autoFilm` setting is on. |
| `recordFilmChoice(photoID, film)` / `forgetFilmChoices()` | Optional, beside `suggestFilm`. Record the film a photograph settled on, against its last ranking, so later rankings learn; forget returns to the hand-set weights. The backend keeps the history on the device. |
| `plugins` | Optional. The plug-ins for other editors the host installs, `[{id, name}]` (Fotufilm Desktop on macOS: `resolve` DaVinci Resolve, `finalCut` Final Cut Pro), from its capabilities. With it come `pluginStatus()`, `installPlugin(id)` and `revealPlugin(id)`; the editor shows a Plug-ins dialog and the host's Plugins menu runs `installPlugin:<id>` / `revealPlugin:<id>` through `useNativeCommands.js`. |
| `pluginStatus()` | Beside `plugins`. `[{id, name, state, bundledVersion?, installedVersion?, hostInstalled, location, note?}]`: `state` is `notBundled` (this build lacks it), `notInstalled`, `outdated` (installed from another build, newer or older) or `installed`; `hostInstalled` whether the editor it is for is on the computer; `note` what to know before installing. |
| `installPlugin(id)` / `revealPlugin(id)` | Beside `plugins`. Install (or reinstall) this build's plug-in, resolving `{message, plugins}` — what to tell the person and every plug-in's new state — after the copy and any registration; reject with a readable message. Reveal shows the installed plug-in in the platform's file manager and rejects when it is not installed. |
| `importPath(path, options)` | Optional, for hosts with a file system. Opens a file the host chose (open panel, Finder, menu) in place; options as `importMedia`. Resolve `{image, url, identity?}`: `identity` is what the file's last edit is kept under (below). |
| `thumbnail({file?, path?}, {signal?, maxEdge?})` | Optional. A small picture of a file opened with others, without decoding it for editing: only the photograph being edited is decoded, and the others show this in the strip until they are chosen. Resolve an object URL the caller revokes, or `null` when the backend cannot draw that file (the strip then shows its name). |
| `openPanel(kind)` | Optional. Shows the host's own open panel for `"image"`, `"video"`, `"all"` or `"filmPack"`; the chosen files arrive as a native open (`fotufilm-native-open`), so they join the host's recent files. Resolves whether anything was chosen. |
| `loadEdit(key)` / `saveEdit(key, text)` | Optional pair, for a host that keeps edits itself. Load resolves the text kept under `key` or `null`; save keeps `text`, or forgets the key when it is `null`. Without them the editor keeps edits in the photo library's IndexedDB records on the device (a desktop host's persistent profile). |
| `filmPacks` | Optional `{list(), importPath(path), importFile(file), remove(packID)}` for hosts that install community film packs into this person's film library (the native host's `filmPacks` capability). `list` → `{packs: [{packID, name, version?, author?, films, stocks, problem?}], changed}`; `changed` means another app added or removed a pack and the films were reloaded. An import (a path the host chose, or a `File`'s bytes) resolves `{added, title, message, update?, packs?}` in the Mac app's words ("Pack added", "Name v1 — 3 films"; "Pack not added" and why; `update` when a newer release is needed) rather than rejecting for a refused pack. `remove` → `{packs}`. After a change the backend's films have been reloaded: call `reloadStocks()` and `loadStocks()` again. |
| `reloadStocks()` | Optional, beside `filmPacks`. Synchronous: forget the loaded film list so the next `loadStocks()` asks the host again. |
| `exportVideo(request)` | Same image/edit/session fields plus `{format,quality,filename,signal,onProgress({progress,frames,finalizing})}`. Return `{filename,url?,dispose()}`; `dispose` releases temporary download resources, never deletes the accepted saved file. |
| `videoExportTypes` | Optional. The movie formats a native encoder writes, `[{id, label, extension, type, quality, bits, colorSpace}]`, replacing the browser's MP4/WebM list; `quality: false` hides the quality choice (ProRes). `format` in `exportVideo` is one of the ids. |
| `lenses` | `{snapshot(),subscribe(listener),load(),import(file,onProgress?),remove()}`. Snapshot is a stable object `{profiles,revision,loaded,error?}` until changed. Subscribe returns an unsubscribe function. Import resolves the installed profile count; remove clears the installed catalogue. Publish a new snapshot on changes or load failure. |

### Images, previews and ownership

An image is a JavaScript descriptor with `naturalWidth`, `naturalHeight`, and a
bounded display-preview `src`. Native descriptors can carry an opaque `handle`;
full-resolution pixel arrays are not required in React or across the bridge.
Optional source metadata uses the existing shape: `raw: {profile?}`, `linear`,
`hdr`, `exr`, and `lensMetadata`. A native host's `hdr` is `{headroom}`, the linear multiple of
diffuse white the source declares; the HDR Highlights controls appear only when it is above 1. These describe the input and
control availability; native descriptors must not expose huge pixel buffers here.
Video descriptors also include `video: {start,duration,playbackUrl}` for the shared
transport controls. Provide a webview-playable proxy URL if the original codec
cannot be played by its media element; processing and export remain native. The
media element is only the clock and the sound: every frame shown is a render at
`videoTime`. A native host whose web view lacks the movie's codecs (Fotufilm
Desktop's Chromium) answers `importVideo`/`importPath` with the sound as a WAV
(`playback`, `playbackType`), silent when the movie is, and the page plays that.

Each successful import grants one image lease. The library releases it on
removal/unmount. `url`/`src` are blob URLs
created by the JavaScript facade and revoked by the UI. Sessions retain any native
input references needed by in-flight work even after the caller releases its lease.
The backend releases its own caches and GPU allocations when the session closes.

### Negative scans

A backend with `negativeScans` opens a scanned negative as a document: `importMedia` or
`importPath` with `negative` decodes it as a scan (camera RAW with no rendering of its own, a file
through its colour profile, an untagged one as linear samples) and its image carries
`negative: {suggestions, lightFrames?}`: up to three `{films: [{id, name}], likelihood}`, the
installed films its clear base looks like, most likely first (films a scan cannot tell apart share
one entry), and the kept light frames where the backend keeps them.

The scan is the film after development, so its edit is any photograph's with `negative` set to
`{border, lightFrame}`: the film is `edit.stock`, chosen in the film library from the films whose
catalogue entry has `readsNegative`; the print is the edit's own. Every render, export and
thumbnail of the document frames the scan with the edit's geometry, reads it as the film's
densities against `border` (clear film as linear Rec. 2020 scan RGB; `null` estimates it from the
thinnest film), evened under the light frame `lightFrame` names where the backend keeps light
frames, and prints it through the
pipeline's print span alone (`PipelineStage.print`). An enlarged paper is timed to the negative's
density. Development and grain do not apply; the light controls act on the print
(`NegativeScanPrint.printing`): exposure and white balance through the enlarger or the scan where
the receiver carries them, and as `PrintFinish` with highlights, shadows, saturation and vibrance
otherwise. The browser's profile request carries `negative: {border, denseEnd, light}`, the clear
film, the framing's densest end and the edit's `ev`, `temperature` and `tint`; the kernels read
the framed scan, and the renderer writes the rest of the light controls into
`FOTUFILM_CONFIG_PRINT_FINISH` per render. With `edit.stock`
`null` the scan is read without a film (`PlainNegativeScan`): each channel's density above
`border`, balanced on the frame's densest end, is taken back to scene light and developed as any
photograph with no film is.

| Member | Input and result |
| --- | --- |
| `sampleFilmBase(result, point)` | Clear film around a unit `point` of a shown render, for `edit.negative.border`, or rejects when the patch is not clear film. |
| `lightFrames()` / `addLightFrame(file)` / `removeLightFrame(id)` | Optional (the desktop host): photographs of the bare light source, kept on the device, that `edit.negative.lightFrame` divides out. |
| `mergeTrichromatic(files, {signal, onProgress})` | Optional. Exposures of negatives under red, green and blue light merged frame by frame into scans (`TrichromaticRoll`): each exposure's light is measured, blanks, exposures under white light and exposures repeated by the next one under the same light are left out, the rest grouped into frames in name order (alternating, or in whole passes), green and blue lined up with red, and the three merged into an untagged 16-bit TIFF. Resolves `{scans: [{path?, file?, name, sources}], failures: [{sources, reason}], blanks, others, repeats, loose}`, `loose` naming the scans whose layers line up only loosely; the editor opens the scans as negatives. Progress is `{progress, status}`. With `choosesExposures` the host asks for the exposures itself and `files` is ignored; it writes each scan beside its red exposure, the browser offers it as a download. |

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
stage?, difference?, cropMode?, showMask?, background?, comparison?, compare?,
purpose?, bitDepth?, stale?, onProgress?}`. Use the existing saved-edit schema unchanged.
`compare` says whether the original is on screen; a host may skip a playing movie's
original while it is not.
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

### Native presentation

A backend with `imageLayer: true` shows the photograph itself, under the page, and never hands
the editor its pixels (`cef/README.md`, Image layer). The editor then:

- passes `present: "preview"` or `present: "detail"` in `render` requests; a result carries
  `presented: {frame, original, dynamicRange, headroom}` in place of `blob`/`original`, and its
  other fields as before (`sceneRequest` for `sampleScene`, `framePlan`, `subjects`);
- adds the `native-image-layer` class to the root element and leaves the photograph's area
  transparent: `useImageLayer.js` cuts it out of the page backgrounds with the
  `--image-hole-*` variables, and the photo plane holds a `.presented-photo` placeholder
  instead of an `<img>`;
- calls `placeImageLayer(geometry)` after every layout or result that moves or changes the
  photograph. The geometry is `{clip, source, layers}`, rectangles as `[x, y, width, height]`
  in CSS pixels: `clip` is the viewer's box, `source` is `"developed"` or `"original"`
  (Compare, Show Original), and each layer is `{slot, frame, original, rect}`: the result's
  two frame ids and where the frame's pixels go, which may run past the clip when zoomed. With
  nothing on show, `layers` is empty.

`createHistogram()` reads presented results through the host's `presentedImage` call, a small
8-bit picture of the last develop (extended range clipped to SDR white), so the histogram keeps
describing what an SDR display shows. The browser backend has no `imageLayer`; its results keep
their blobs.

## Verification

`backend.test.js` checks versioning, binding, resource ownership and the static UI
dependency boundary. `backend-histogram.test.js` exercises cancellation/error
races. `native-backend.spec.js` and `native-resources.spec.js` supply a test-only native double and drive the
real editor without fetching browser engine assets. It is a contract integration
test, **not evidence of native rendering performance or image-quality parity**.
When implementing a real host, run the same UI suite against it and compare
representative CPU/Metal/WebGPU output before shipping.
