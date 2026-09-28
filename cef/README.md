# Fotufilm Desktop (CEF host)

One editor on every desktop: the React editor in `web/` is the presentation layer, shown by the
Chromium Embedded Framework, and the native engine (Swift and Halide) does the work. The host is
C++ with a thin platform layer per operating system.

Status: the host runs on macOS. The editor loads from the app bundle and develops through the
native engine: `libfotufilm` (`fotufilm.h`, built from `Sources/FotufilmHost` with the Mac app's
ahead-of-time Halide Metal kernels) answers the transport's methods, which is installed as
`window.fotufilmNativeTransport`. Methods the engine does not answer yet reject with a message
(see [Roadmap](#roadmap)). A host built without the library installs the transport as
`window.fotufilmDesktop`, a name the editor does not look for, and the editor keeps its browser
engine.

## Build and run

You need CMake, Ninja, Node and, on macOS, Xcode.

```sh
cef/build.sh               # fetch CEF, build the engine library, plug-ins and web/, build the host
cef/build.sh --run         # …then open the bridge diagnostics page
cef/build.sh --no-plugins  # …without the Resolve and Final Cut plug-ins
```

`cef/fetch-cef.sh` downloads the CEF version pinned in `cef-version.env` into `build/cef/` and
checks its SHA-1. `cef/build-engine.sh` builds `build/cef-engine/libfotufilm.dylib` and the
films and camera profiles it reads, which the app carries in `Frameworks` and `Resources`.
`tools/build-editor-plugins.sh` builds the DaVinci Resolve OFX
bundle and, where Apple's FxPlug SDK is installed, the Final Cut Pro wrapper; the app carries them
in `Resources`. The app is `build/cef-host/Release/Fotufilm.app`.
Switches:

| Switch | Effect |
| --- | --- |
| `--fotufilm-diagnostics` | Opens the bridge diagnostics page instead of the editor. |
| `--fotufilm-dev-url=http://127.0.0.1:5173` | Loads the editor from the Vite dev server, with hot reload; that origin gets the transport. |
| `--fotufilm-web-root=<dir>` | Serves another web build as `fotufilm://app/`. |
| `--fotufilm-profile=<dir>` | Keeps the browser profile there, so a second copy can run beside the first. |
| `--fotufilm-export-dir=<dir>` | Writes exports there under their suggested names, without a save panel, for scripted runs. |
| `--remote-debugging-port=9333` | Chromium's DevTools protocol, for DevTools and Playwright. |

## Design

```text
 React editor (renderer process)                 host (browser process)
 ───────────────────────────────                 ─────────────────────────────────────────
 window.fotufilmNativeTransport ──── call ─────▶ Dispatcher ─▶ UI-thread handlers
   postMessage({id,method,params}, payload?)       │          (layout, window, compositor)
                                  ◀─── reply ────   └───────▶ engine thread (Swift/Halide)
 page, drawn off-screen ─── IOSurface / D3D11 / dmabuf ─▶ compositor ─▶ window
                                                     engine image ─▶┘  (image under the page)
```

Latency is decided by what never crosses a boundary:

- **The image never passes through the page.** The engine writes a finished render into a
  shared surface (an IOSurface on macOS) that the host's compositor draws beneath the page, which
  is transparent over the photograph ([Image layer](#image-layer)). There is no encoding, no IPC
  of pixels and no Chromium composite between a finished render and the glass. Measured: sending
  a 4K RGBA8 frame to the page and back costs about 10 ms even over shared memory, which is why
  it is kept for thumbnails and histograms only.
- **The page is off-screen and shared as a texture.** Chromium paints the UI into an IOSurface
  (D3D11 shared handle on Windows, dmabuf planes on Linux). The compositor copies it on the GPU
  (0.3–0.5 ms at 2880×1864) without waiting on the main thread, and blends it premultiplied over
  the image layer in one pass (≈50–100 µs of encoding).
- **One frame clock.** On macOS 14 and later a `CAMetalDisplayLink` with a one-frame latency
  target hands the compositor a drawable timed for the next refresh. It runs at the panel's rate
  (120 Hz on ProMotion) and sleeps while nothing changes. The main thread never waits for a
  drawable; with a plain display link it waited up to a whole refresh.
- **Messages are small and direct.** A call is one CEF process message; a reply goes back to the
  script context that sent it. Payloads (file bytes, thumbnails) travel in one shared-memory
  region beside the message instead of inside JSON. Measured round trip, page → host → page:
  46 µs mean on the UI thread, 48–57 µs through the engine thread (M4 Pro).
- **Engine work stays off the UI thread**, in order, on the engine thread, so input and painting
  never wait for a render.

The transport keeps the contract in `web/src/backend/README.md` and the call shape of
`web/src/backend/desktop/transport.js`, so the editor's native backend needs no second transport.

### Files

| Path | Role |
| --- | --- |
| `src/app/scheme.*` | `fotufilm://app/` serves the bundled web build: no local server or port. |
| `src/app/library_folders.*`, `library_methods.*` | The photo library's folders: the host's panel, listing, and the files at `fotufilm://app/.library`. |
| `src/app/browser_app.*` | CefApp for the browser and child processes; passes switches to renderers. |
| `src/app/client.*` | One off-screen browser: paint, cursor, keys, context menu, bridge messages. |
| `src/bridge/protocol.h` | Message names and the shared-memory frame layout. |
| `src/bridge/dispatcher.*` | Routes calls to UI-thread or engine-thread handlers; replies; cancellation. |
| `src/renderer/bridge.js` | The page-side transport, compiled into the renderer. |
| `src/renderer/renderer_bridge.*` | Installs the transport in trusted pages; returns replies to their context. |
| `src/presentation/presentation.h` | The image presenter and its surfaces: the interface every platform implements. |
| `src/presentation/image_layer.*` | Which presented frame each layer draws, and where the page shows them. |
| `src/presentation/compositor_core.*` | Every compositor's decisions: when to draw, the plan of quads, EDR, frame pacing, the latency probe. |
| `src/presentation/pooled_presenter.*` | Surface reuse and the hand-over of presented frames; a platform supplies only its surfaces. |
| `src/presentation/presentation_methods.*` | The page's `setImageLayer`, compositor stats, snapshot and probe calls, for every platform. |
| `src/engine/engine_bridge.*` | Loads `libfotufilm`, runs it on the engine thread, lends it the presenter. |
| `src/platform/mac/` | Window, input forwarding, the Metal half of the compositor, app and helper entry points. |
| `src/platform/mac/image_presenter.*` | The presenter on macOS: a pool of IOSurfaces shared with Metal. |
| `src/platform/mac/main_menu.*` | The Mac app's menu bar, Open Recent and the Plugins menu. |
| `resources/diagnostics/` | Bridge diagnostics: round trips, payloads, native-layer alignment. |

### Image layer

The engine reports `imageLayer` in its capabilities when the host lends it a presenter
(`fotufilm_engine_set_presenter` in `fotufilm.h`). The editor then leaves the photograph's area
transparent and sends its geometry with `setImageLayer` whenever layout, zoom or pan change:
the viewer's clip, and for each layer (`preview`, `detail`) its rectangle in CSS pixels and the
frame it should show. A render that names a slot (`present: {slot, scope}`) develops as before
but copies the region into a surface the presenter lends (`acquire`), hands it over
(`present`), and answers `presented: {frame, original, dynamicRange, headroom}` with no pictures.
The undeveloped frame goes to `<slot>.original` only when it changes, so Compare swaps layers
without a render. `presentedImage` returns the last develop as a small PNG for the histogram.

On macOS a surface is an IOSurface, written by the engine and read by Metal without a copy. The
compositor keeps the last frames of each layer and draws, inside the viewer's clip, the one the
page placed, or a newer frame of the same size and scope as soon as it arrives. That frame goes
on screen at the next refresh, with no wait for the page to lay out. A playing movie's frames
(`motion` in the present info) cut in rather than fade, one new frame a refresh in the order
they came, so two finished within one refresh are both seen. A placement takes effect
with the next browser frame, the one that carries the matching layout, or after 50 ms if none
comes. Crop handles, masks, the zoom readout and every other overlay are page content drawn over
the layer. Selection sampling reads the scene through `sampleScene`, not the picture.

Colour: the drawable is Display P3, and the page is converted from sRGB as it is blended. While a
frame on show was delivered in extended range and the screen reports headroom (the window's
screen `maximumPotentialExtendedDynamicRangeColorComponentValue`, re-read when the window moves
or the display changes), the drawable is RGBA16F extended-linear Display P3 with EDR requested.
The engine develops such a frame in display-linear P3 and maps it with
`HLGTransfer.previewDisplayLight` up to the smaller of the headroom and the film's HDR display
ceiling, so below SDR white it matches the 8-bit frame. It delivers extended range only when the
film does (`supportsHDRDelivery`), and not for pipeline stages, print frames or selective
edits, which stay 8-bit.

A Linux or Windows port implements `ImagePresenter` (dmabuf or a D3D11 shared handle) and draws
the `ImageLayer`'s frames in its compositor. The engine side is platform-neutral: surfaces are
pixels plus a row stride.

### Menu bar and files

The menu bar follows the native Mac app's, item for item, wherever the editor has the
action. An item sends `fotufilm-native-command` {command}, and the editor runs the handler its own
toolbar or shortcut uses (`web/src/editor/useNativeCommands.js`); the editor reports which commands
apply and which are ticked with `menuState`, which the menus validate against. A shortcut goes to
the menu bar before the page, so a key an item takes never also reaches the page's bindings; Undo,
Redo and the clipboard belong to a focused text field when there is one.

Edit › Undo and Redo are named after the step they change ("Undo Lens Correction"), and Edit ›
Edit History lists every step of the shown photograph, the current one ticked, as the Mac app's
does; choosing one runs `history:<step>`. The editor reports the names with `menuState`
(`titles`, `history`); a focused text field keeps plain Undo and Redo.

Files from File > Open, Open Recent, the Finder (double-click, Open With, the Dock icon) arrive as
`fotufilm-native-open` {paths}, held until the editor listens, and the engine opens them in place
with `importPath`: no bytes cross the bridge. Its answer carries the file's `identity` (the
SHA-256 of a still's bytes, from the platform's `HostPlatform.fileDigest`; name, size and date for
a movie or where there is no digest), under which the editor keeps the photograph's last edit, so
reopening it starts where it was left. The edits live in the editor's IndexedDB in the profile
(`Application Support/Fotufilm Desktop`); a host may keep them itself with `loadEdit`/`saveEdit`
(`web/src/backend/README.md`). Files dropped on the window become a CEF drag, so
the page's own drop handling takes them. Copy Photo develops the frame and the engine puts it on
the pasteboard (`copyImage`).

Film › Choose Film Per Photo ranks every film for each newly opened photograph as the Mac app
does (`suggestFilm`, from `FotufilmStockMatch`) and applies the best; the film a photograph keeps
is recorded (`recordFilmChoice`) in `Application Support/Fotufilm Desktop/StockPreference.json`,
and Forget What I've Taught It clears it (`forgetFilmChoices`).

File › Import Film Pack… (⇧⌘I) is the Mac app's: an open panel for `.fotufilmpack` files, whose
paths reach the editor as any opened file does (so does a pack double-clicked in the Finder, which
the app offers to open without owning the type), and the editor installs them with
`importFilmPack` {path}; a pack chosen in the page (Options › Import Film Pack…, Settings, a drop)
crosses as bytes. The engine checks it exactly as the Mac app does (`FilmPackLibrary` in
FotufilmCore, shared with `CustomStockStore`): a community pack this release reads, with valid
films, under an id that is not the person's own films; refusals and "Pack added — Name v1 — 3
films" read as the Mac app's alert, and a pack needing a newer release asks for an update. Packs
go into the directory the platform names (`HostPlatform.filmPacks`); on macOS that is the Mac
app's own custom store (`FilmPackLibrary.directory`, Application Support/CustomPacks, or
FotufilmSource/CustomPacks for source builds), which neither app is sandboxed out of, so a pack
added in either app, or for the plugins, shows in both. The engine then reloads its films and
warms the new ones without restarting, and the editor asks for its film list again.
`filmPacks` lists the installed community packs (and notices packs another app added since),
`removeFilmPack` {packID} takes one away; Settings › General lists them with Remove. The engine is
compiled with the same pack key material the Mac app is (`FOTUFILM_PACK_KEY_SOURCE`, defining
`FOTUFILM_PACK_KEY_MATERIAL`), and the page offers all of this only when the capabilities say
`filmPacks`.

Fotufilm › Settings… (⌘,) opens the editor's Settings dialog (`web/src/editor/SettingsDialog.jsx`),
which every backend shares: the starting film, format and film model of new photographs, film
suggestions, and HDR photo export, kept on the device in `web/src/app-settings.js`.

### Plug-ins

The Plugins menu is the Mac app's: Install (Reinstall once there) and Show in Finder for DaVinci
Resolve and Final Cut Pro. The engine installs them with the Mac app's own installers
(`Sources/FotufilmPlugins`, compiled into both): the OFX bundle into `/Library/OFX/Plugins`, asking
for an administrator password only when that folder is not writable, and the FxPlug wrapper into
`/Applications` with its Motion template, launched once so macOS registers the extension. The
platform's `HostPluginInstaller` (`HostPlatform.plugins`) lists its plug-ins in the capabilities
(`plugins: [{id, name}]`), from which the menu is built, and answers `plugins` (each one's state:
`notBundled`, `notInstalled`, `outdated` — installed from another build — or `installed`, with
both versions), `installPlugin` and `revealPlugin`. The editor's Plug-ins dialog
(`web/src/editor/PluginsDialog.jsx`, also under the options menu) shows the state and the answer
of an install; at launch it offers this build's plug-ins for the editors on the computer, as the
Mac app's alert does, and remembers a Not Now against the build. A Linux or Windows port adds its
own installer for the folders its editors read, and the menu and dialog follow. An install holds
the engine thread until it is done, as the Mac app's menu item holds its own.

### Video

Movies decode and encode through the platform's `HostPlatform.videoSource` and `.videoWriter`
(`Sources/FotufilmHost/HostVideo.swift`); on macOS these are AVFoundation, reading Apple Log,
S-Log, F-Log, HLG and PQ as untouched code values into scene-linear Rec. 2020 as the Mac app
does. The engine reports `video` and `videoExportTypes` in its capabilities only when a
platform supplies both. CEF's Chromium carries no H.264, HEVC or ProRes decoder, so the page
never plays the movie itself: the import answers with its sound as a WAV (silent when the
movie is), which the editor's media element plays as the clock, and every frame on screen is a
native render at that time. Playback reads the movie forward with one open decoder and asks for
the engine's realtime schedule; a scrub opens the decoder at the new time. An export's save
panel goes through the same `DestinationPicker` as a still's, and its progress arrives as
`fotufilm-native-progress` events for the call.

Video Quality is shared by Settings and the export dialog. Full develops at the chosen delivery
size. Fast uses a reduced film develop, up to a 1920-pixel long edge, followed by a full-size
print for compatible 8-bit sources and outputs. Deep sources and deliveries retain their
float pipeline. Selective edits and unsupported film models use the ordinary full-resolution
develop. Both stages of a Fast print share the scene's measured Digital Reference levels.
Several independent frames develop in flight and are written in presentation order; trim,
audio, cancellation, grain animation and lower frame-rate delivery are retained.

On Metal, the 8-bit path converts the decoded scene into Display P3 codes on the GPU before
developing it. The CPU conversion remains the fallback if the GPU conversion or its buffers
are unavailable. For profiling, `FOTUFILM_VIDEO_TIMINGS=1` reports export stages and
`FOTUFILM_VIDEO_CPU_INPUT=1` selects the CPU input conversion for comparison.

### Matching the native editor

An unspecified output medium starts on Digital Reference, matching the Mac editor. Explicit
paper choices are retained. The native backend applies the edit's halation model and measures
crop coverage before rounding the preview raster, so film-scale effects retain their physical
size across preview resolutions. Standard Range uses the platform's SDR rendition for processed
photos; Automatic and Full Range keep the decoded highlights. RAW remains scene-linear.

### Negative scans

File › Import Scanned Negative… opens the apps' negative-scan session
(`web/src/negative-scan/`, `Sources/FotufilmHost/HostService+NegativeScan.swift`) when the engine
reports `negativeScans`. The scan is decoded once as the apps' importer reads it
(`NegativeScanImport` behind `HostPlatform.scans`: a camera RAW with no rendering choices, other
files through their colour profile or, by choice, as linear samples) and held as linear
Rec. 2020. Every preview prints the page's `NegativeScanRecipe` from it: the automatic reading,
or the scan's densities on a chosen negative film through the engine's print stage on Digital
Reference, an RA-4 paper or the lab scanner (`HalideMetalFilmRenderer.printScan`, or the Halide
CPU print stage without a GPU), with the film base sampled by dragging over clear film or
estimated from the thinnest film, exposure, warmth, tint, contrast (paper grade in black and
white), highlights and shadows, a light frame divided out, and rotate, flip, straighten and crop
with Find Frame. The recipe's print arithmetic is the apps' own
(`Sources/FotufilmEditModel/NegativeScanPrint.swift`); turning, straightening, cropping and the
light are plain arithmetic in `HostNegativeScan`, so a Linux or Windows port needs only a scan
decoder. Framings, automatic plans and film balances are kept per framing, so a slider prints
without reading the scan again. Import Positive opens the full-resolution print in the editor with
no film, as the Mac app's importer does. Light frames live in
`Application Support/Fotufilm Desktop/LightFrames`, in the apps' JSON form.

## Roadmap

1. **Engine methods.** `prepare` (with the film library), `import`, `preview`, `release`,
   `render` (geometry, viewport tiles cut from one develop), `autoAdjust`, `sampleScene`,
   `export` (PNG, 16-bit TIFF, JPEG, HEIC, to a native save panel), `importPath`, `copyImage`,
   print frames (`printFrame`, framed renders and exports), lens correction (`lensPlan`, the
   catalogue, and the correction in the geometry resample), negatives (the negative-scan
   session's `negativeScanOpen`, `negativeScanRender`, `negativeScanSampleBorder`,
   `negativeScanDetectFrame`, `negativeScanCommit` and light frames; the older automatic
   `analyseNegative`, `convertNegative` and `suggestNegativeFilms`), the pipeline inspector (`stages`,
   stage and difference renders), selective edits by colour, light or subject (Vision's
   foreground instances, as the Mac app selects), film suggestion, the Resolve and Final Cut
   plug-ins (`plugins`, `installPlugin`, `revealPlugin`), film packs (`filmPacks`,
   `importFilmPack`, `removeFilmPack`) and video answer today: movies
   upload in 8 MB binary chunks or open in place, render the frame at `videoTime` through the
   same geometry and film, and export (`exportVideo`, with progress and cancel) as H.264, 10-bit
   HEVC or Apple ProRes 422/4444 with the sound carried across; HEVC and ProRes write BT.2100 HLG when HDR is on and the film delivers it.
2. **Native presentation in the editor.** Done ([Image layer](#image-layer)). Still to do: the
   engine's Metal develop writes into the surface directly instead of into memory it then copies,
   and the layer follows the viewer's fades.
3. **Colour.** Done: Display P3, and EDR where the film and the screen allow. Still to do:
   extended range for selective edits, stages and print frames, and a new render when only the
   headroom changes (a brightness change applies at the next render).
4. **Windows and Linux.** The same host with a D3D11 compositor (shared handles) and a Vulkan
   compositor (dmabuf), and Halide GPU targets for each; Swift is shipped with the app there.
   What such a compositor decides is already shared (`compositor_core.h`): a port supplies a
   `PresentationSurface`, a `PooledPresenter`, a `WindowCompositor` and the draw of each
   `CompositePlan`, and registers `RegisterPresentationMethods`. `libfotufilm` builds on Linux
   (`cef/build-engine-linux.sh`) and opens, scans and exports stills through the system's codec
   libraries (`Sources/CFotufilmCodecs`: JPEG, PNG, TIFF, HEIF/AVIF, OpenEXR and camera RAW in;
   PNG, 16-bit TIFF, JPEG and HEIC out, SDR). On Ubuntu:
   `apt install libjpeg-turbo8-dev libpng-dev libtiff-dev libraw-dev liblcms2-dev libopenexr-dev
   libheif-dev`, with `libheif-plugin-libde265` and `libheif-plugin-x265` for HEIC at run time.
5. **Host completeness.** IME composition, native `<select>` popups,
   accessibility, window chrome from `window-chrome.js`, and signing and notarisation of the app
   and its helpers.

## Checks

`cef/tests/run.sh` builds and runs the portable presentation and library folder checks with the
system compiler, no CEF or GPU needed, so they run on every platform the host targets.

The photo library's folders are picked, listed and read by the host (`app/library_methods.h`),
since Chromium's own folder picker refuses a home, Documents, Desktop or Downloads folder as a
whole. The page reads only folders chosen in the host's panel, which it keeps between launches.

The diagnostics page (`--fotufilm-diagnostics`) measures round trips on both threads, echoes
64 KB to 4K RGBA16F payloads and verifies their bytes, and draws a moving pattern in the native
layer behind a hole in the page: the pattern must stay inside the orange frame while the frame is
resized.

The bridge answers these calls for tests driven over the DevTools protocol:

| Call | Answer |
| --- | --- |
| `compositorStats` | Frame counts, copy and composite times, `extendedRange` and `headroom`. |
| `compositorSnapshot` | Path of a composite of page and image layer: PNG, or half-float TIFF while extended. |
| `probePixel` {x, y} | Watches one point: every change is composited at once and read back (an empty object stops it). |
| `probeReport` | `now` and each change's commit time (ms, the host's clock: `CACurrentMediaTime` on macOS) and pixel value. |

Latency from input to pixels: arm `probePixel` on the photograph, read `probeReport`'s `now`,
send a key to a slider, and take the first change whose value moved by the step. Changes are
timed at commit, at most one refresh before the glass.
