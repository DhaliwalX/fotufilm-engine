# Scanned negatives in FotufilmCore

`ScannedNegativeConverter` measures densities from linear scanner or camera samples.
An explicit `ScanDensityCalibration` maps those measurements into the film-record
density format consumed by the engine's existing print stage.

The desktop and browser editors read a scan as a film and print it (below). The native apps
also offer [automatic conversion](automatic-negative-conversion.md) without a drawn reference. The CLI does not
yet expose scanned-negative conversion.
No scanner profiles or automatic calibration fitting are bundled. A supplied affine
profile is an approximation: validate its colour accuracy over the density range you
use. Some capture setups need a nonlinear profile beyond this API.

## Input preparation

- Decode RAW or the scan's known transfer curve into linear capture-channel values.
  Sixteen-bit storage alone does not mean a TIFF is linear. Do not pass ordinary
  display RGB, already inverted positives, or auto-levelled scans as measurements.
- Use the same channel basis and capture exposure for the scan, dark reference and
  light reference. Correct uneven illumination before conversion. Avoid saturation;
  the converter cannot identify a scanner's clipped maximum from float values alone.
- For `.clearLight`, measure unobstructed light. For `.filmBase`, measure an unexposed,
  developed border of the same film. The latter removes the measured base and fog;
  the calibration offset must restore the target film model's base contribution.

Each scanner channel is measured as:

```text
transmission = (sample - dark) / (light - dark)
scannerDensity = -log10(transmission)
filmRecordDensity = calibrationMatrix * scannerDensity + calibrationOffset
```

The matrix has one row per engine film record (R, G, B) and one column per scanner
channel (R, G, B). The matrix and offset must be calibrated for the capture setup,
film model and development settings used for printing. Sampling the border alone
does not calibrate dye cross-talk. An identity matrix is appropriate only when the
input channels already measure the target records, such as a synthetic test fixture.

## Swift integration

The following function takes decoded linear samples and measured calibration values;
it does not fit or invent a scanner profile.

```swift
import FotufilmCore

func convertScan(
    _ scan: ImageBuffer,
    dark: SIMD3<Float>,
    filmBorder: SIMD3<Float>,
    calibrationRows: [SIMD3<Float>],
    calibrationOffset: SIMD3<Float>,
    stock: FilmStock
) throws -> ImageBuffer {
    let converter = try ScannedNegativeConverter(
        dark: dark, light: filmBorder, reference: .filmBase)
    let calibration = try ScanDensityCalibration(
        reference: .filmBase, rows: calibrationRows, offset: calibrationOffset)
    var options = FotufilmEngine.Options()
    options.paper = .screen
    return try FotufilmEngine(stock: stock, options: options)
        .printScannedNegative(linearScan: scan, converter: converter,
                             calibration: calibration)
}
```

The result is display-linear Display P3 RGB. Use the appropriate output encoding and
colour-space conversion when saving it. A linked Halide backend is required to print.

For diagnostics, `converter.scannerDensity(linearScan:)` returns scanner-channel
densities only. Do not pass those directly to `.print`. To inspect the calibrated
intermediate or render it on Metal, call
`converter.negativeDensity(linearScan:calibration:)`, then use the existing float
density input with `options.stage = .print`. Never encode densities with a display
transfer curve or send them through an 8-bit image path.

The convenience method always enters at the print boundary, irrespective of
`options.stage`. It does not redevelop the negative or add film halation and grain.
Print-medium effects still apply. It rejects reversal stocks and negative-viewing
output settings. Select the stock and lab settings that the calibration targets.

Invalid reference spans, malformed buffers, nonfinite samples, samples at or below
the dark reference, mismatched reference kinds, and calibrated densities outside
`NegativeInterchange.range` throw `ScannedNegativeError`. Densities are not clipped
to hide measurement errors. Samples brighter than the reference may produce negative
scanner densities, which is useful with a film-border reference.

## Shared approximate import and browser print boundary

`ApproximateNegativeScan` contains the editor's border normalization, film-base restoration,
monochrome record mapping and usable-range mask. Set it as `FotufilmEngine.Options.scanReading`
and hand the print span (`stage = .print`) linear scan RGB in place of densities: the kernels read
each sample as `density(of:)` does and print the samples it cannot place black. `convert` reads a
whole buffer in Swift, for reference. Neither alters the source scan nor fits a scanner profile.
`NegativeScanPreparation` runs the kernels that divide a light frame out of a scan and read a
scan without a film (`PlainNegativeScan`).

The browser profile protocol's film request takes `negative: {border, denseEnd, light}`: the clear
film as three linear scan values, the framed picture's densest end
(`ApproximateNegativeScan.denseEnd`, or nothing for a frame too small to read), and the edit's
`ev`, `temperature` and `tint`, which the enlarger or the scan takes. It prepares the print
profile `NegativeScanPrint.Reading.printing` describes, which enters the WebGPU or SIMD renderer
with the framed scan as its input, bypassing exposure and development. The renderer writes
highlights, shadows, saturation and vibrance into the print's finish
(`FOTUFILM_CONFIG_PRINT_FINISH`) at render time. A scan read without a film goes through the scan
preparation module (`tools/build-negative-wasm.sh`). Color and monochrome print kernels warm
independently from positive-photo kernels.

To compare the shipped browser kernels against native scan printing, generate synthetic
references, start the web development server, then run the pixel check:

```sh
FOTUFILM_SCAN_REFERENCE_DIRECTORY="$PWD/build/negative-reference" \
  swift test -c release --parallel --filter WebNegativeProfileRequestTests
node tools/test-negative-kernels.mjs http://127.0.0.1:5173/
```

The check requires actual WebGPU, compares linear output before display encoding, and checks
16-bit Display P3 delivery through the background worker. References and build output stay in
the ignored build directory.

## Film suggestions

`NegativeFilmSuggestions` ranks the installed negative films a scan could be, from the colour of
its clear film base. Each film's base is predicted from its spectral model as a colorimetric scan
white-balanced on its light source records it. `read(preview:)` finds the base in a linear
Rec.2020 preview as the thinnest density plateau. When a neutral light shows past the film's edge
with an orange base under it, the base is read against that light. `suggest(_:)` fits each scan's
colour saturation, since cameras record the mask about 1.25 times as saturated as colorimetry
predicts, and returns suggestions with a likelihood share.

A light frame of the bare light source, captured like the scan, also fixes the base's overall
density. Only then can black-and-white films, whose bases differ only in density, be told apart.
Films with the same predicted base are suggested together. Suggestions are a starting point:
fading, fog, processing and a scanner's own channel response move a real base as far as films of
one family sit apart. A scan white-balanced on the film border shows no mask and reads as
black-and-white film. Tone-mapped JPEG or PNG captures distort the base's colour; use raw or
linear captures.

```sh
swift run -c release fotufilm --suggest-film scan.dng [--light-frame light.dng]
swift run -c release fotufilm --list-film-bases
```

## Editor

Choose **Import Scanned Negative…** and open unconverted negatives. Each opens as
a photo of its own, read as a film and printed through the same print stage a simulated
photo uses. Supported camera RAW files are decoded with every rendering choice off; TIFF,
PNG and other images use their file colour profile, and a file without one is read as
linear samples. Sixteen-bit storage alone does not establish linearity. Use unadjusted
scans: automatic levels, local contrast, clipping and prior inversion cannot be undone.

The film chosen in the film library is the film the scan is read as; only negative films
are offered, and the scan starts on the film its clear base looks like. The scan is
measured against its clear film base: estimated from the thinnest film of the scan, or
sampled from a patch of developed, unexposed film, avoiding the holder, sprocket holes,
edge numbers and image detail. Each record's density above the base is balanced on the
frame's densest end and mapped onto the film model, restoring its base density.
Monochrome uses the green density for all records. In the desktop app, a photograph of the
bare light source divides out uneven scanning light.

A library folder can be kept as a folder of scanned negatives. Its photos open as negatives, and
its thumbnails show each scan read without a film, its clear base estimated from the thumbnail.
A frame opened for the first time starts from the film, film settings, clear film and light
frame of the folder's frame edited last, as frames of one roll share them.

With **Normal**, the scan is read without a film and edited as a plain positive photograph.
Each channel's density above the clear base is balanced on the frame's densest end and taken
back to scene light along a straight-line negative of gamma 0.6, the densest end landing on
diffuse white (`PlainNegativeScan`). Every photo control then applies; no print simulation
does.

Those densities then take the print exactly as a simulated negative does: every output
medium, lamp, screen conversion and print frame applies, and an enlarged paper is timed
to the negative's density, as a lab times each frame. Development and grain act before the
negative existed and do not apply. Crop, rotation and straightening are the editor's own and
are saved with the edit; the scan itself is never changed.

The light controls act on the print (`NegativeScanPrint.printing`). On an enlarged paper,
exposure and white balance are the enlarger's: a stop of exposure takes a third of a stop of
printing light away, since a colour paper's contrast at mid-grey is about three picture stops
per stop of light (2.7 on Crystal Archive to 3.5 on Endura Premier), and warmth and tint move
the yellow and magenta filtration by log10(2)/3 density per stop of balance, a warmer print
taking yellow away. On Digital Reference and Lab Scan, exposure is the scan's exposure. Whatever
the receiver cannot carry, and highlights, shadows, saturation and vibrance, finish the printed
picture before the grade (`PrintFinish`): gains, then the ends of its luminance moved by up to
0.75 stops, easing in over three stops above mid-grey and four below, then chroma. A
black-and-white print takes no colour. Lens, source illuminant and regional tone shape scene
light the scan never had and do not apply.

The conversion is approximate. RAW decoding disables tone boosts, highlight recovery,
lens correction and noise reduction, but retains the decoder's colour processing. These
are not sensor-channel measurements. No measured scanner profile is fitted or included.
Flare and colour cross-talk remain uncorrected. Nonpositive, nonfinite and out-of-range
pixels, commonly the holder, print black; they are not assigned invented densities. Crop
away the holder.

In **Crop**, drag each of the four circular handles independently. The selection must
remain convex and cannot cross itself. Leaving Crop (or pressing Return) straightens
the selected quadrilateral into a rectangle. Preview and full-resolution export use
the same normalized corners. **Four-Corner Crop** also enables this mode for ordinary
photos; choosing an aspect ratio returns to a rectangular crop. Reset Crop clears the
selection. Rotating and flipping move the four corners with the image. Undo and redo
restore corner edits. While dragging, the crop uses a cached display preview and
keeps changes local to the canvas. Releasing the handle commits one undoable edit;
film thumbnails refresh after leaving Crop. Export uses the full-resolution source.
