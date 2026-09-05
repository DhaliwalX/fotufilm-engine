# Fotufilm for DaVinci Resolve

Default builds include Gold 200, Tri-X 400, and Provia 100F from the free
[Starter pack](../licenses/STARTER-PACK.txt).

This plugin adds Fotufilm to a Resolve node. It uses the same engine and stock
files as the Mac app and command-line tool.

## Build and install

Run these commands from the repository root. You need Xcode 26 or newer and Halide.

```sh
brew install halide
resolve/build.sh --test
```

This creates `build/resolve/Fotufilm.ofx.bundle` and runs a small test host that
renders frames without opening Resolve.

To install the plugin:

```sh
resolve/build.sh --install
```

The plugin is installed in `/Library/OFX/Plugins`. Restart Resolve, then find
**Fotufilm** under **OpenFX**. You can also install it through the Fotufilm Mac app.

## Use the plugin

1. Add **Fotufilm** to a node.
2. Choose a film. **Match Film** selects that film's default gauge.
3. Check **Timeline Color Space** and its status line.
4. Leave **Stage** on **Full** to render the complete film and print process.
5. Adjust exposure, output medium, lens filters, film response, and development.

Source builds include synthetic example films and print models. They do not need
activation. Some controls are unavailable when the selected film does not support them.
The status line explains why.

The inspector groups controls under Setup, Film, Exposure & Colour, Lens & Filters,
Development, Grain, Halation, Colour Separation, and Output. Start with these settings:

| Setting | What it controls |
| --- | --- |
| Film Format / Resolved Format | Film size and the format selected by Match Film. |
| Film Frame Coverage (%) | How much of the film frame is used by the image. |
| Push / Pull | Development conditions offered by the selected stock. |
| Long Exposure (s) | Reciprocity correction, when the stock provides the data. |
| Grain Animation / Grain Seed | Moving or frozen grain and its repeatable pattern. |
| Mottle | The amount of coarse clumping in the grain. |
| Return Spectrum | Halation strength across seven wavelength bands. |
| Render Mode / Effective Renderer | Realtime or Reference rendering. |

A smaller film format makes grain and other spatial effects larger in the image.
**Output Medium** selects how the developed film is viewed or printed. The status
fields show the format, medium, and renderer actually in use.

## Match the input color space

**Auto (from host)** uses the color information Resolve provides. Check the status
line to see the space it selected. In an unmanaged Resolve YRGB project, an image
tagged Raw is treated as DaVinci Wide Gamut / Intermediate. Select the input space
manually if your node receives a different space.

Finished prints are fitted to narrower timeline primaries before output encoding.
Colors already inside that gamut are unchanged.

Unknown named spaces produce an error. Hosts without color tags use Rec.709 Gamma
2.4. Log or linear footage can retain highlight detail that an SDR image has lost.

## Pipeline stages

| Stage | What it does |
| --- | --- |
| Full | Develops the film and produces the final image. |
| Negative Only | Produces optical-density data for a Print Only node. |
| Print Only | Turns that density data into the final image. |
| Texture Only | Adds selected spatial effects to the input image. |

Place **Negative Only** immediately before **Print Only**. Use the same film,
gauge, and development settings in both nodes. Do not put grading, resizing, blur,
or a color conversion between them: the intermediate values are data, not an image.
Use a 32-bit float path to preserve them.

## Test a built bundle

After `resolve/build.sh --test`, the test host can load a bundle directly:

```sh
build/resolve/host-harness build/resolve/Fotufilm.ofx.bundle/Contents/MacOS/Fotufilm.ofx
```

Use `--parity-dump <path>` to save the shared test frame for comparison with the
Final Cut test host. These tests do not replace checking the plugin inside Resolve.

## Build for distribution

`--universal` builds for Apple silicon and Intel Macs. Local builds use an ad-hoc
signature. To sign with a Developer ID certificate:

```sh
FOTUFILM_CODESIGN_IDENTITY="Developer ID Application: …" resolve/build.sh --universal
```

Notarization is a separate step. The build checks the signature, bundled resources,
dynamic-library dependencies, and exported symbols. Halide compiles the kernels
during the build; users do not need to install Halide.

Desktop version numbers come from `version.env`. Keep the plugin identifier and
major version stable so saved projects can find the effect.

## Code and custom packs

`FotufilmPlugin.cpp` handles Resolve's plugin interface. `FotufilmBridge.swift` and
`FotufilmBridge.h` connect it to the engine. `WorkingSpace.cpp` handles color-space
conversions and is shared with the Final Cut plugin.

Set `FOTUFILM_STOCKS` to a folder of stock JSON files to load custom films. If a
custom film and a bundled pack use the same ID, the bundled pack takes precedence.
See [Build support](../docs/support.html) for custom pack builds and
[Licensing](../LICENSING.md) for applicable terms.
