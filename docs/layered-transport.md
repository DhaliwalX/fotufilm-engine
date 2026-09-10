# Experimental layered transport

The planar engine and CLI can replace legacy halation and emulsion MTF with an
explicit optical construction. Existing films keep their existing rendering unless
a construction is supplied. No included commercial film is relabeled as measured
layered transport.

```sh
swift run -c release fotufilm input.exr output.png --stock example-negative-400 \
  --transport construction.json --halation 1 --grain 0
```

Use an existing stock ID from `--list-stocks`. `--transport-backend metal` runs the
transport convolutions through Halide Metal JIT; spectral scene preparation and
development use the CPU reference with either backend. This is not an end-to-end GPU
renderer. `cpu` is the default. An unavailable backend produces a render error.

Use `--iterations 31` to measure 30 repeated warm frames after the first render.
The report includes median and p95 processing latency and achieved frames per second.
Warm timings exclude image decoding and output encoding and include scene preparation,
transport, development, and output-medium processing. They are sequential repeated-image
measurements; a 4K30 workload needs each 3840×2160 frame in 33.33 ms. Failed renders
abort the benchmark instead of contributing a timing sample.

In Swift, decode and validate a `LayeredTransport`, assign it to
`FotufilmEngine.Options.layeredTransport`, and call
`try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)`.
Input is linear Rec.2020 with middle grey at 0.18. Full, negative, print, and texture
stage semantics are retained. The throwing entry point reports preparation and
unsupported-feature errors. The older nonthrowing entry point retains its fatal
error convention.

## Construction contract

`LayeredTransport` is a Codable construction with `revision: 1` and
`kind: "conditional-launch"`. It contains:

| Field | Meaning |
| --- | --- |
| `constructionID`, `provenance` | Identifier and `illustrative`, `inferred`, or `measured` evidence label |
| `wavelengthsNM` | Exactly the engine's 81 samples, 380–780 nm at 5 nm intervals |
| `layers` | Front-to-rear layers: unique ID, thickness in mm, refractive index, and absorption in inverse mm |
| `frontIndex`, `rearIndex` | Surrounding media at the two external interfaces |
| `rearReflectance` | Optional opaque backing reflectance; the complement is absorbed. Omit for the dielectric rear interface |
| `recordDepthMM` | Three capture planes measured from the exposing surface, in R/G/B record order |
| `angularExponent` | Three cosine-power conditional launch distributions |
| `captureProbability` | Three probabilities of capture per subsequent crossing of the receiver plane |
| `returnedToDirect` | Three independently supplied returned/direct response ratios |
| `coreSigmaMM` | Three compact no-return Gaussian widths; replaces, rather than adds to, legacy MTF |

Spectral fields accept either one constant or all 81 samples. Three-row fields
use one spectrum per receiver. A `FilmStockDefinition` carrying a construction
uses schema 3. Schemas 1 and 2 reject that field; schema 3 requires it and rejects
conflicting legacy halation profiles and return matrices. Other stock data and
the developed/printed response remain available.

## Optical and numerical model

The solver follows an unpolarized forward launch from each receiver, splitting
s and p power at each actual dielectric interface. Snell's invariant determines
the angle in each layer. Beer attenuation uses the oblique path length. Rear
reflections tag returned paths; each later crossing captures a declared fraction.
Paths with equal segment traversal counts merge exactly in power. The solver
tracks returned capture, capture before a rear return, absorption, escape, and
unresolved power. It fails if the unresolved conditional power exceeds `1e-7`.
Angular quadrature is deterministic; this residual is not an angular integration
error bound.

Each solved returned kernel is normalized separately from its return amount.
For receiver c and wavelength λ, `alpha = ratio / (1 + ratio)` partitions
no-return and returned exposure. Both kernels are nonnegative and integrate to
one. The positive spectral component tables sum to the stock's calibrated
pointwise exposure table, including its gamut continuation. Thus spatially
uniform colours retain their calibrated exposure at every amount.

The amount control scales all wavelength/receiver return shares together up to
one, then approaches a positive saturation endpoint smoothly above one. It does
not refit the angular distribution or reinterpret amount as an absorption change.
Return Spectrum changes the wavelength ratios before normalization. Source Colour
blends toward a common positive spatial endpoint as an explicit creative control.

The compiler fits convex pairs from at most eight solved radial basis kernels,
plus the three compact no-return kernels. It checks the edge-spread fit at 128
distances and adds the uniform error bound from equal-mass radial compression
(`0.5/512` when compression is used). The default combined threshold is 0.005.
This sampled fitting certificate does not certify the optical inputs, angular
integration, or the final multiresolution discretization.

Pixel weights integrate the overlap of translated pixel cells with each radial
quadrature node. Narrow and broad radial bands use separate grid scales, so a
distant tail cannot blur the inner shoulder. Each stencil is positive and
normalized. Reduction uses positive area weights and reconstruction uses smooth,
positive cubic B-spline weights at reduced scales; stride one keeps the original
pixel samples. Camera, native Metal, Halide, and portable reconstruction agree.
The image boundary extends the nearest true edge pixel. Components and
radial bands stream one at a time; amount changes reuse cached endpoint tables.

## Scope and limitations

This is the conditional-launch analytical model, not a solved volumetric
multiple-scattering radiative-transfer equation. It does not infer optical constants
or commercial-film calibration from stock names. The no-return core and return
ratios are supplied independently; captured conditional power is not an absolute
scene-photon absorption measurement.

The current execution paths use whole-frame intermediates with streamed components.
A fixed working-memory budget and transport strip scheduling are not implemented.
Donor capture layers, additional Gaussian support haze and stage-sequence exports
are rejected. Apple camera capture encodes transport in the same command buffer as
its existing HDR frame graph; the editor and plugin hosts use the AOT transport path.
Browser transport packs use SIMD WebAssembly. Model selection and export details
are described below.

## Reproduce the A/B

```sh
FOTUFILM_TRANSPORT_AB_OUTPUT=/tmp/fotufilm-transport-ab \
  swift test -c release --filter LayeredTransportComparisonTests
```

On macOS this writes legacy/layered PNGs, a Metal comparison when available, the
illustrative construction JSON, and numeric metrics. The scene, construction,
and negative stock are synthetic. The test uses the same scene, return strengths,
gauge, development, and print on both sides; grain, adjacency, and local tone are
disabled to make optical differences legible. The comparison is a diagnostic of
the models, not evidence that the construction matches a specific film stock.

## Model selection across hosts

`Options.halationModel` selects `legacy` (default) or `layered`. An explicit
`Options.layeredTransport` construction overrides that selector. With `layered`, the
stock's construction is used when present; otherwise the engine creates an explicitly
illustrative stack from the selected format and the stock's return strength and core
spread. This fallback is not a measured stock calibration.

Mac and iOS persist the selector in Film Model settings. Resolve appends bridge slot
49, and Final Cut appends parameter 88; zero retains Legacy for existing projects.
Apple hosts use AOT scene/development passes and native Metal transport convolution.
The reference API retains CPU and Metal JIT convolution for validation. Native zoomed
previews currently develop the complete virtual frame before cropping to preserve
transport tails and reduction-grid alignment. This increases memory use at high zoom.

`--halation-model legacy|layered` selects the CLI model. Browser pack version 3 adds
head/tail configurations, component exposure LUTs and positive weighted stencils to
the version 2 size-ladder layout. `tools/build-wasm.sh` exports both `.pack` and
`.layered.pack` for supported stocks. The index declares `layeredTransport: false` for
donor-layer stocks, which currently require Legacy on every host. The browser reports
that limitation without substituting models. Layered packs use the SIMD backend,
including when WebGPU is available;
Legacy keeps its existing WebGPU/SIMD selection. Runtime exposure, colour and grain
controls work with either model. Layered stage-sequence exports and browser lens
flare/diffusion pack overrides are rejected explicitly. Rebuild every AOT kernel and
browser pack after the appended record-exposure configuration slot; old pack/config
length mismatches are rejected by the runtime. Browser transport develops a complete
frame to preserve convolution support and reduction-grid alignment; its memory use
therefore grows with the full image, even when Legacy would render in tiles.
