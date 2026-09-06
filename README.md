# Fotufilm engine

Fotufilm is an open-source film simulation engine built to be as physically
accurate as possible.
This repository includes the engine, a command-line tool, a Mac app, plugins for
DaVinci Resolve and Final Cut Pro, and a browser demo.

## Build the engine

On a Mac, install Xcode 26 or newer and Halide:

```sh
brew install halide
swift build
swift test -c release --parallel
```

CI runs only when started manually in GitHub Actions.

If Halide is installed elsewhere, set `HALIDE_ROOT` to its installation folder.

List the included films or process an image from the command line:

```sh
swift run fotufilm --list-stocks
swift run fotufilm input.jpg output.jpg --stock gold200
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

## Included films

Default source builds include all 40 film profiles, free to use without activation.
The runtime JSON profiles are available in `Sources/FotufilmCore/Stocks/` under
[CC BY-SA 4.0](licenses/FILM-PROFILES.txt). You may modify and redistribute them
with attribution and ShareAlike terms. This licence does not apply to rendered
photos or videos. The engine code uses Apache-2.0.

Thirty-three profiles carry sampled characteristic curves with smooth interpolation
through every validated digitized point. Source tracing variations are retained;
response outside each published range is extrapolated. These schema version 2
profiles require a build with sampled-curve support. Schema version 1 remains supported.

The CLI and tests also include synthetic films. Print models use calculated
example curves, not measured paper profiles. The demo uses a generated colour chart.
See [Build support](docs/support.html) for stock-pack setup.

`SOURCE_ASSETS.json` records where assets came from and their file hashes. Before
adding data or images, run `python3 tools/check-source-boundary.py`.

[Download for Mac](https://github.com/DhaliwalX/fotufilm-engine/releases/latest/download/Fotufilm-macOS.pkg) · [![Download on the App Store](docs/assets/download-on-the-app-store.svg)](https://apps.apple.com/app/id6792911908)

## More information

- [User guide](docs/documentation.html)
- [Build support](docs/support.html)
- [Licensing](LICENSING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

The engine, Mac app, and plugins use [Apache-2.0](LICENSE). Film profiles have
[separate licences](LICENSING.md).
