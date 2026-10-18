# Fotufilm editor in Flutter

A prototype of the editor drawn by Flutter in the web editor's look (`web/src`, compact desktop
layout), from one UI for the desktop and the browser.

- **Desktop:** the engine (`libfotufilm`, `Sources/CFotufilmHost/include/fotufilm.h`) is called
  through `dart:ffi` on its own isolate. Developed pictures are written straight into platform
  textures through the engine's presenter, so no image is encoded on the way to the screen.
- **Browser:** the UI is compiled to WebAssembly and calls the web editor's WASM and WebGPU engine
  through `web/src/flutter-bridge.js`, which answers the same host calls the native engine does.

## Layout

Each feature keeps its state and actions in one model file and its UI in its own files. The
`EditorModel` attaches the features, and a few registries let them plug in without touching
each other.

| Path | What it holds |
| --- | --- |
| `lib/app/` | The window: workspace layout, commands (one list for the macOS menu bar, its native menu, and Ctrl shortcuts elsewhere), keyboard dispatch, the host window's services |
| `lib/model/editor.dart` | The open photographs and their histories, the panels, the view, and the features it attaches |
| `lib/model/renderer.dart` | What the engine develops and when: the shown picture, the magnified detail, and background thumbnails for rows on screen |
| `lib/model/<feature>.dart` | One file per feature: crop, selective, pipeline, negatives, lens, print frame, band sets, edit history, presets, kept edits, Auto Adjust, film suggestions, export, video, the photo library and strip, settings, film packs, plug-ins, updates, panel layout, the CEF app's profile brought over once (`cef_profile/`) |
| `lib/engine/` | The engine connection (`engine.dart`): native (`dart:ffi` isolate) and browser (JS bridge); the native presenter channel |
| `lib/ui/theme/` | Colours, every size and space (`metrics.dart`), type |
| `lib/ui/kit/` | Spectrum-style controls: buttons, fields, sliders, menus, popovers |
| `lib/ui/inspector/` | The inspector shell, `panels.dart` (which sections each panel shows) and one file per panel or section |
| `lib/ui/workspace/` | Toolbar, film library, viewer and `viewer_tools.dart` (the canvas tools' overlays), photo strip, histogram, dialogs, the photo library (`library/`) |
| `lib/debug/` | The scripted-check driver, with a file of commands per area |
| `macos/Runner/` | The presenter (IOSurface-backed textures), its Metal colour conversion, the native menu and the window's services |

Features plug in through:

- `Panel` (`model/editor.dart`) and `ui/inspector/panels.dart`: the inspector's tabs and canvas tools.
- `EditorModel.renderOptionSources`: what the shown picture's develops carry beyond the edit
  (`cropMode`, `stage`, `difference`, `showMask`, `printFrame`, video time).
- `EditorModel.editListeners`: every change to a photograph's history.
- `ui/workspace/viewer_tools.dart`: overlays over the photograph.
- `AppSettings` (`model/settings.dart`): preferences and remembered things, kept on the device.

## Building on macOS

```sh
flutter/build.sh                    # build/flutter-host/Fotufilm.app, with the engine and plug-ins
```

It builds the engine (`cef/build-engine.sh`) and the Resolve and Final Cut plug-ins
(`--no-plugins` leaves them out), then the app; `FLUTTER` names the flutter tool. A source build
is an app of its own (`com.muastudio.fotufilm.source`, no release feed); an official build
(`FOTUFILM_SOURCE_BUILD=0`) takes the Mac app's identity and feed, so it replaces the installed
app in place. To iterate on the UI alone:

```sh
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
a line, and answers in `<dir>/log`. The commands drive every feature (opening, films, panels, the
canvas tools, negatives, editing, export, the library, video, menus and keys), take snapshots, and
time opening, films and slider drags; see `lib/debug/driver.dart` and the files beside it.
`FOTUFILM_EXPORT_DIR` saves exports there without asking.

## Platforms

macOS and the browser run today. Linux and Windows runners, with their presenters, are still to
come.
