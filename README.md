# Fotufilm engine

Fotufilm simulates how film records light and how a print turns it into an image.
This repository includes the engine, a command-line tool, a Mac app, plugins for
DaVinci Resolve and Final Cut Pro, and a browser demo.

## Build the engine

On a Mac, install Xcode 26 or newer and Halide:

```sh
brew install halide
swift build
swift test -c release --parallel
```

If Halide is installed elsewhere, set `HALIDE_ROOT` to its installation folder.

List the included films or process an image from the command line:

```sh
swift run fotufilm --list-stocks
swift run fotufilm input.jpg output.jpg --stock example-negative-400
```

## Build the Mac app and plugins

The Mac app targets Apple silicon and macOS 14 or newer.

```sh
macos/build.sh --test
```

Open `build/macos/Fotufilm.app`. The build also includes the Resolve plugin.
To include the Final Cut plugin, install Apple's FxPlug SDK first. See the
[Resolve guide](resolve/README.md) and [Final Cut guide](finalcut/README.md)
for separate builds and installation steps.

## Build the browser demo

Install Emscripten and Python 3.10 or newer. Set `EMSDK_ROOT` to your Emscripten
SDK folder, or install it at `build/emsdk`. Then run:

```sh
tools/build-wasm.sh
cd web
npm ci
npm run build
```

The output is in `web/dist`. The demo uses the CPU when a WebGPU-compatible
Halide toolchain is not available.

## Included examples

The app runs without activation. It includes three synthetic films, example print
models, and a generated color chart. These examples show how the engine works.
See [Build support](docs/support.html) to supply your own stock packs.

`SOURCE_ASSETS.json` records where assets came from and their file hashes. Before
adding data or images, run `python3 tools/check-source-boundary.py`.

## More information

- [User guide](docs/documentation.html)
- [Build support](docs/support.html)
- [Contributing](CONTRIBUTING.md)
- [Licensing](LICENSING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
