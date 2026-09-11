# Fotufilm for DaVinci Resolve

Default builds include all 40 free
[film profiles](../licenses/FILM-PROFILES.txt), licensed under CC BY-SA 4.0.

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

To add a pack, open the Fotufilm Mac app and choose **Load custom pack…**.
Restart your video editor after importing or updating it. Its films appear in the
plugin automatically on the same Mac and user account. Keep the app and plugins
updated together; packs that need a newer version are skipped.

1. Add **Fotufilm** to a node.
2. Choose a film. **Match Film** selects that film's default gauge.
3. Check **Timeline Color Space** and its status line under **Input**.
4. Leave **Stage** (under **Pipeline**) on **Full** to render the complete film and print process.
5. Adjust light and colour, lens filters, development, grain, halation, and output medium.

The plugin includes all 40 film profiles and example print models. No activation
is needed. If a control is unavailable for your film, the status line explains why.

The inspector groups controls in the order the light passes through them: Input, Film,
Light & Colour, Lens & Filters, Development, Grain, Halation, Colour Separation, Output, and
Pipeline. Input, Film, and Output start open; Pipeline holds **Stage** and **Render Mode** and
starts closed. Start with these settings:

<table>
<thead><tr><th>Control</th><th>Group</th><th>What it does</th></tr></thead>
<tbody data-controls="resolve-controls">
  <tr><td>Timeline Color Space</td><td>Input</td><td>What this node is being handed — the one control that is not taste.</td></tr>
  <tr><td>Stock</td><td>Film</td><td>The emulsion.</td></tr>
  <tr><td>Film Format</td><td>Film</td><td>The gauge the frame is exposed on.</td></tr>
  <tr><td>Film Frame Coverage (%)</td><td>Film</td><td>Short edge of the film frame retained after cropping.</td></tr>
  <tr><td>Exposure</td><td>Light &amp; Colour</td><td>Camera exposure, in stops.</td></tr>
  <tr><td>Temperature (K)</td><td>Light &amp; Colour</td><td>Spectral scene temperature.</td></tr>
  <tr><td>Tint</td><td>Light &amp; Colour</td><td>Green/magenta balance of the illuminant.</td></tr>
  <tr><td>Highlights</td><td>Light &amp; Colour</td><td>Scene-referred highlight recovery, applied before the film model.</td></tr>
  <tr><td>Shadows</td><td>Light &amp; Colour</td><td>The same shift, fading in below mid-grey.</td></tr>
  <tr><td>Regional Tone Mask</td><td>Light &amp; Colour</td><td>Off, the highlight and shadow shifts key to each pixel's own luminance instead of to the region it sits in.</td></tr>
  <tr><td>Saturation</td><td>Light &amp; Colour</td><td>Chroma multiplier applied to the scene before the film responds.</td></tr>
  <tr><td>Vibrance</td><td>Light &amp; Colour</td><td>Chroma boost weighted toward the least colourful pixels; already-vivid colours are left alone.</td></tr>
  <tr><td>Scene Illuminant</td><td>Light &amp; Colour</td><td>Capture light presented to the film; Temperature and Tint adjust this spectrum.</td></tr>
  <tr><td>Scene Illuminant (K)</td><td>Light &amp; Colour</td><td>Custom capture light before the Temperature and Tint edits.</td></tr>
  <tr><td>Filter 1</td><td>Lens &amp; Filters</td><td>An absorbing filter on the front of the lens.</td></tr>
  <tr><td>Filter 2</td><td>Lens &amp; Filters</td><td>A second filter, behind the first.</td></tr>
  <tr><td>Filter 3</td><td>Lens &amp; Filters</td><td>A third filter, behind the second.</td></tr>
  <tr><td>Metering</td><td>Lens &amp; Filters</td><td>How the exposure was set with those filters fitted.</td></tr>
  <tr><td>Diffusion</td><td>Lens &amp; Filters</td><td>A diffusion filter on the front of the lens.</td></tr>
  <tr><td>Diffusion Grade</td><td>Lens &amp; Filters</td><td>The particle loading a product line's 1/8, 1/4, 1/2, 1 and 2 name: one formulation more heavily loaded, so the grade moves how much light takes part and never how far it goes.</td></tr>
  <tr><td>Focal Length</td><td>Lens &amp; Filters</td><td>The taking lens's focal length in millimetres, read only by the diffusion filter: a ray deviated by an angle ahead of the lens lands focal length times that angle off its unscattered position, so the same filter glows bigger on a longer lens, exactly as it does in the world.</td></tr>
  <tr><td>Veiling Glare</td><td>Lens &amp; Filters</td><td>Veiling glare from the taking lens, as a multiplier on the stock's figure.</td></tr>
  <tr><td>Filter Coating</td><td>Lens &amp; Filters</td><td>Coating on every fitted absorbing and diffusion filter.</td></tr>
  <tr><td>Push / Pull</td><td>Development</td><td>Measured push or pull conditions for this film's stated developer, dilution, temperature and agitation.</td></tr>
  <tr><td>Bleach Bypass</td><td>Development</td><td>How much of the developed silver the bleach leaves in the negative.</td></tr>
  <tr><td>Film Age (years)</td><td>Development</td><td>Years the roll sat past its process-by date.</td></tr>
  <tr><td>Long Exposure (s)</td><td>Development</td><td>Exposure duration for the stock's measured reciprocity response.</td></tr>
  <tr><td>Grain</td><td>Grain</td><td>Multiplier on the stock's measured granularity.</td></tr>
  <tr><td>Mottle</td><td>Grain</td><td>Use the stock's coarse grain mixture, or set a custom share.</td></tr>
  <tr><td>Mottle Amount (%)</td><td>Grain</td><td>Share of grain variance carried by coarse clumping.</td></tr>
  <tr><td>Grain Animation</td><td>Grain</td><td>Timeline changes grain each frame.</td></tr>
  <tr><td>Grain Model</td><td>Grain</td><td>Disc grain is available on silver-image stocks and requires Reference rendering, selected automatically.</td></tr>
  <tr><td>Grain Seed</td><td>Grain</td><td>Same seed and same frame give the same grain.</td></tr>
  <tr><td>Halation Model</td><td>Halation</td><td>Legacy or layered optical transport.</td></tr>
  <tr><td>Halation</td><td>Halation</td><td>Multiplier on the fraction of light the base returns.</td></tr>
  <tr><td>Estimated Halation Shape</td><td>Halation</td><td>Renders halation through the stock's provisional annular profile — the reflex ring at the base's critical angle — where no independently calibrated profile exists.</td></tr>
  <tr><td>Halo Colour</td><td>Halation</td><td>How much the halo keeps the source's own colour instead of the film's layered red.</td></tr>
  <tr><td>Return Spectrum</td><td>Halation</td><td>Gain over the stock's halation return spectrum.</td></tr>
  <tr><td>DIR Couplers</td><td>Colour Separation</td><td>Multiplier on inter-image inhibition, the mechanism behind the stock's colour separation and its Mackie lines.</td></tr>
  <tr><td>Separation</td><td>Colour Separation</td><td>Interlayer inhibitor reach.</td></tr>
  <tr><td>Edge Contrast</td><td>Colour Separation</td><td>Within-layer inhibition.</td></tr>
  <tr><td>Fringe Amount</td><td>Colour Separation</td><td>Broad inter-layer transport fraction, 0-1.</td></tr>
  <tr><td>Fringe Radius (µm)</td><td>Colour Separation</td><td>Broad transport Gaussian sigma on the film, 20-300 micrometers.</td></tr>
  <tr><td>Red–Green Reach</td><td>Colour Separation</td><td>Additional multiplier on Separation for the red–green interlayer.</td></tr>
  <tr><td>Green–Blue Reach</td><td>Colour Separation</td><td>Additional multiplier on Separation for the green–blue interlayer.</td></tr>
  <tr><td>Output Medium</td><td>Output</td><td>Choose where the finished image lives.</td></tr>
  <tr><td>Viewing Illuminant</td><td>Output</td><td>Choose the light used to judge a physical print.</td></tr>
  <tr><td>Enlarger</td><td>Output</td><td>The lamp house a reflection print is enlarged under.</td></tr>
  <tr><td>Channel Contrast Match</td><td>Output</td><td>Digital correction of channel-contrast mismatch, not physical printer timing.</td></tr>
  <tr><td>Negative Viewing</td><td>Output</td><td>How the developed negative is read when Output Medium is Negative.</td></tr>
  <tr><td>Stage</td><td>Pipeline</td><td>Which span of the pipeline this node performs.</td></tr>
  <tr><td>Texture Stages</td><td>Pipeline</td><td>Whether Texture Only carries this stage.</td></tr>
  <tr><td>Render Mode</td><td>Pipeline</td><td>Default preserves the launch-time renderer setting.</td></tr>
</tbody>
</table>

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

The **Halation Model** menu selects **Legacy** (the default for older projects) or
**Layered Transport**. Layered Transport uses an illustrative construction when the
stock has no measured stack. **Estimated Halation Shape** affects Legacy only.
