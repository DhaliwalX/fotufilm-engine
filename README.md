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

The output is in `web/dist`. The demo develops an image at its own size, up
to about 120 megapixels, cutting it into tiles the kernel runs one at a time;
the pack carries its spatial parameters for a ladder of frame sizes so grain
and halation stay the size the emulsion makes them. The demo uses the CPU when
a WebGPU-compatible Halide toolchain is not available. To build one, install Homebrew's `llvm` and
`lld` and run `tools/build-halide.sh --webgpu` first; it fetches the Halide
pull request the browser runtime needs and applies the patches in `tools/`.

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

The CLI and tests also include synthetic films. The demo uses a generated colour chart.
See [Build support](docs/support.html) for stock-pack setup.

## Print media

The output media are digitised from the manufacturers' own published datasheets, on the
same 380-780 nm grid at 5 nm the film model uses. Each carries the sheet's dye spectra,
layer sensitivities and characteristic curves.

| Medium | Source |
| --- | --- |
| Kodak Ektacolor Edge | Kodak E-7020 (April 2019) |
| Kodak Professional Endura Premier | Kodak E-4070 (March 2013) |
| Fujicolor Crystal Archive Type CA | Fujifilm AF3-0250U2 (November 2018) |
| Kodak Vision 2383 | Kodak H-1-2383 (March 2022) |
| Kodak Vision Premier 2393 | Kodak 2393 curve sheets |
| Fujifilm ETERNA-CP 3513DI | Fujifilm ETERNA-CP 3513DI brochure |

A sheet that publishes one characteristic curve develops all three records along it;
E-7020, E-4070 and 2393 publish three and are carried per record. The lab scan and
telecine are inversions rather than sheets, and are described in `PrintPaperTables.swift`.

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
