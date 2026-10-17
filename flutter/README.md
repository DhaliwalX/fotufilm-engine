# Fotufilm editor in Flutter

A prototype of the editor drawn by Flutter in the web editor's look (`web/src`, compact desktop
layout), from one UI for the desktop and the browser.

- **Desktop:** the engine (`libfotufilm`, `Sources/CFotufilmHost/include/fotufilm.h`) is called
  through `dart:ffi` on its own isolate. Developed pictures are written straight into platform
  textures through the engine's presenter, so no image is encoded on the way to the screen.
- **Browser:** the UI is compiled to WebAssembly and calls the web editor's WASM and WebGPU engine
  through `web/src/flutter-bridge.js`, which answers the same host calls the native engine does.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/app/` | The window: workspace layout, commands (the macOS menu bar, Ctrl shortcuts elsewhere), the host window |
| `lib/model/` | Editor state and history, the renderer that decides what the engine develops and when, the control catalogue, film types |
| `lib/engine/` | The engine connection (`engine.dart`): native (`dart:ffi` isolate) and browser (JS bridge); the native presenter channel |
| `lib/ui/theme/` | Colours, every size and space (`metrics.dart`), type |
| `lib/ui/kit/` | Spectrum-style controls: buttons, fields, sliders, menus, popovers |
| `lib/ui/workspace/` | Toolbar, film library, viewer, photo strip, histogram, dialogs |
| `lib/ui/inspector/` | The inspector shell and one file per panel |
| `macos/Runner/` | The presenter (IOSurface-backed textures) and its Metal colour conversion |

## Building on macOS

```sh
cef/build-engine.sh                 # build/cef-engine: libfotufilm.dylib and its resources
cd flutter
tool/prepare.sh                     # stages the control catalogue, glyphs and fonts
flutter build macos --release
```

The Xcode build bundles the engine from `../build/cef-engine`; set `FOTUFILM_ENGINE_BUILD` to use
another `cef/build-engine.sh` output. `FOTUFILM_APPEARANCE=light|dark` overrides the system
appearance.

## Building for the browser

```sh
cd flutter
tool/build-web.sh                   # build/web: the UI as WebAssembly, engine/bridge.js beside it
node tool/serve-web.mjs --assets <a browser build's web/public>
```

The bridge fetches the engine's runtime assets (its WASM modules and film packs, built by
`tools/build-wasm.sh`) from `engine/`; `serve-web.mjs` serves them from `--assets` without
copying. Deploying copies them to `engine/` beside the build. `?FOTUFILM_APPEARANCE=dark` in the
page's address overrides the system appearance. The browser engine needs WebGPU.

## Scripted checks

With `FOTUFILM_DRIVER_DIR=<dir>` set, the app reads commands from `<dir>/commands`, one JSON object
a line, and answers in `<dir>/log`. The commands include opening photographs, choosing films and
panels, snapshots, scrolling, zoom, compare, export, and a slider benchmark; see
`lib/debug/driver.dart`.

## Platforms

macOS and the browser run today. Linux and Windows runners, with their presenters, are still to
come.
