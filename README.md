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

Default source builds run without activation and bundle the free Starter pack: Gold 200,
Tri-X 400, and Provia 100F. These calibrated profiles use
[CC BY-ND 4.0](licenses/STARTER-PACK.txt); the engine code has separate terms.

The CLI and tests also include synthetic films. Print models use calculated
example curves, not measured paper profiles. The demo uses a generated colour chart.
See [Build support](docs/support.html) for stock-pack setup.

`SOURCE_ASSETS.json` records where assets came from and their file hashes. Before
adding data or images, run `python3 tools/check-source-boundary.py`.

[Download for Mac](https://github.com/DhaliwalX/fotufilm-engine/releases/latest/download/Fotufilm-macOS.pkg) · [![Download on the App Store](docs/assets/download-on-the-app-store.svg)](https://apps.apple.com/app/id6792911908)

To convert a scan, choose **File → Import Scanned Negative…**, sample its clear film
border and preview the positive. Import it to adjust all four crop corners independently.
See the [scan import guide](docs/scanned-negatives.md) for input requirements and
the approximate conversion’s limits.

## More information

- [User guide](docs/documentation.html)
- [Build support](docs/support.html)
- [Licensing](LICENSING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

The engine, Mac app, and plugins use [Apache-2.0](LICENSE). Film profiles have
[separate licences](LICENSING.md).
