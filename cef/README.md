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
cef/build.sh          # fetch CEF, build the engine library and web/, build the host
cef/build.sh --run    # …then open the bridge diagnostics page
```

`cef/fetch-cef.sh` downloads the CEF version pinned in `cef-version.env` into `build/cef/` and
checks its SHA-1. `cef/build-engine.sh` builds `build/cef-engine/libfotufilm.dylib` and the
films and camera profiles it reads, which the app carries in `Frameworks` and `Resources`. The app
is `build/cef-host/Release/Fotufilm Desktop.app`. Switches:

| Switch | Effect |
| --- | --- |
| `--fotufilm-diagnostics` | Opens the bridge diagnostics page instead of the editor. |
| `--fotufilm-dev-url=http://127.0.0.1:5173` | Loads the editor from the Vite dev server, with hot reload; that origin gets the transport. |
| `--fotufilm-web-root=<dir>` | Serves another web build as `fotufilm://app/`. |
| `--fotufilm-profile=<dir>` | Keeps the browser profile there, so a second copy can run beside the first. |
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

- **The image never passes through the page.** The engine renders into a GPU texture that the
  host's compositor draws beneath the page, which is transparent over the photograph. There is no
  readback, no encoding, no IPC of pixels and no Chromium composite in the path from a finished
  render to the glass. Measured: sending a 4K RGBA8 frame to the page and back costs about 10 ms
  even over shared memory, which is why it is kept for thumbnails and histograms only.
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
`web/src/backend/macos/transport.js`, so the editor's native backend needs no second transport.

### Files

| Path | Role |
| --- | --- |
| `src/app/scheme.*` | `fotufilm://app/` serves the bundled web build: no local server or port. |
| `src/app/browser_app.*` | CefApp for the browser and child processes; passes switches to renderers. |
| `src/app/client.*` | One off-screen browser: paint, cursor, keys, context menu, bridge messages. |
| `src/bridge/protocol.h` | Message names and the shared-memory frame layout. |
| `src/bridge/dispatcher.*` | Routes calls to UI-thread or engine-thread handlers; replies; cancellation. |
| `src/renderer/bridge.js` | The page-side transport, compiled into the renderer. |
| `src/renderer/renderer_bridge.*` | Installs the transport in trusted pages; returns replies to their context. |
| `src/platform/mac/` | Window, input forwarding, Metal compositor, app and helper entry points. |
| `src/platform/mac/main_menu.*` | The Mac app's menu bar and Open Recent. |
| `resources/diagnostics/` | Bridge diagnostics: round trips, payloads, native-layer alignment. |

### Menu bar and files

The menu bar is the Mac app's (`macos/FotufilmApp/MacMainMenu.swift`) wherever the editor has the
action. An item sends `fotufilm-native-command` {command}, and the editor runs the handler its own
toolbar or shortcut uses (`web/src/editor/useNativeCommands.js`); the editor reports which commands
apply and which are ticked with `menuState`, which the menus validate against. A shortcut goes to
the menu bar before the page, so a key an item takes never also reaches the page's bindings; Undo,
Redo and the clipboard belong to a focused text field when there is one.

Files from File > Open, Open Recent, the Finder (double-click, Open With, the Dock icon) arrive as
`fotufilm-native-open` {paths}, held until the editor listens, and the engine opens them in place
with `importPath`: no bytes cross the bridge. Files dropped on the window become a CEF drag, so
the page's own drop handling takes them. Copy Photo develops the frame and the engine puts it on
the pasteboard (`copyImage`).

Film › Choose Film Per Photo ranks every film for each newly opened photograph as the Mac app
does (`suggestFilm`, from `FotufilmStockMatch`) and applies the best; the film a photograph keeps
is recorded (`recordFilmChoice`) in `Application Support/Fotufilm Desktop/StockPreference.json`,
and Forget What I've Taught It clears it (`forgetFilmChoices`).

Fotufilm › Settings… (⌘,) opens the editor's Settings dialog (`web/src/editor/SettingsDialog.jsx`),
which every backend shares: the starting film, format and film model of new photographs, film
suggestions, and HDR photo export, kept on the device in `web/src/app-settings.js`.

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

## Roadmap

1. **Engine methods.** `prepare` (with the film library), `import`, `preview`, `release`,
   `render` (geometry, viewport tiles cut from one develop), `autoAdjust`, `sampleScene`,
   `export` (PNG, 16-bit TIFF, JPEG, HEIC, to a native save panel), `importPath`, `copyImage`,
   print frames (`printFrame`, framed renders and exports), lens correction (`lensPlan`, the
   catalogue, and the correction in the geometry resample), negatives (`analyseNegative`,
   `convertNegative` with contrast, `suggestNegativeFilms`), the pipeline inspector (`stages`,
   stage and difference renders), selective edits by colour, light or subject (Vision's
   foreground instances, as the Mac app selects), film suggestion and video answer today: movies
   upload in 8 MB binary chunks or open in place, render the frame at `videoTime` through the
   same geometry and film, and export (`exportVideo`, with progress and cancel) as H.264, 10-bit
   HEVC or Apple ProRes 422/4444 with the sound carried across; HEVC and ProRes write BT.2100 HLG when HDR is on and the film delivers it.
2. **Native presentation in the editor.** A backend capability that lets `ImageCanvas` leave the
   photograph's area transparent and report its rectangle, zoom and pan to the host (as
   `setImageLayer` does in the diagnostics page); renders then go to the image layer instead of
   returning blobs. The browser engine keeps today's path.
3. **Colour.** A wide-gamut, extended-range drawable (Display P3, EDR) for the image layer, with
   the page converted from sRGB in the compositor.
4. **Windows and Linux.** The same host with a D3D11 compositor (shared handles) and a Vulkan
   compositor (dmabuf), and Halide GPU targets for each; Swift is shipped with the app there.
5. **Host completeness.** IME composition, native `<select>` popups,
   accessibility, window chrome from `window-chrome.js`, and signing and notarisation of the app
   and its helpers.

## Checks

The diagnostics page (`--fotufilm-diagnostics`) measures round trips on both threads, echoes
64 KB to 4K RGBA16F payloads and verifies their bytes, and draws a moving pattern in the native
layer behind a hole in the page: the pattern must stay inside the orange frame while the frame is
resized.
