# Fotufilm desktop editor in Flutter

A prototype of the desktop editor drawn natively by Flutter, in the web editor's look (`web/src`,
compact desktop layout). The engine (`libfotufilm`, `Sources/CFotufilmHost/include/fotufilm.h`)
is called through `dart:ffi` on its own isolate. Developed pictures are written straight into
platform textures through the engine's presenter, so no image is encoded on the way to the screen.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/app/` | The window: workspace layout, commands (the macOS menu bar, Ctrl shortcuts elsewhere), the host window |
| `lib/model/` | Editor state and history, the renderer that decides what the engine develops and when, the control catalogue, film types |
| `lib/engine/` | The C interface, the engine isolate and the native presenter channel |
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

## Scripted checks

With `FOTUFILM_DRIVER_DIR=<dir>` set, the app reads commands from `<dir>/commands`, one JSON object
a line, and answers in `<dir>/log`. The commands include opening photographs, choosing films and
panels, snapshots, scrolling, zoom, compare, export, and a slider benchmark; see
`lib/debug/driver.dart`.

## Platforms

macOS runs today. Linux and Windows runners, with their presenters, are still to come.
