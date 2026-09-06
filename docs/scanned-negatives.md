# Scanned negatives in FotufilmCore

`ScannedNegativeConverter` measures densities from linear scanner or camera samples.
An explicit `ScanDensityCalibration` maps those measurements into the film-record
density format consumed by the engine's existing print stage.

The Mac app offers an approximate import workflow described below. The CLI does not
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

## Mac app import

Choose **File → Import Scanned Negative…** and open an unconverted negative with
its developed, unexposed film border visible. Supported camera RAW files are decoded
with Core Image; TIFF, PNG and other ImageIO images use their file colour profile.
Choose **Linear Samples** only for a scan exported with a linear transfer curve.
Sixteen-bit storage alone does not establish this. Use unadjusted scans: automatic
levels, local contrast, clipping and prior inversion cannot be undone by the importer.

Drag a rectangle over clear film, avoiding the holder, sprocket holes, edge numbers
and image detail. The importer takes a median RGB sample of that patch. Choose the
closest installed negative film, then **Preview Positive**. Use **Show Negative** to
sample again. **Import Positive** converts at full resolution and opens the Crop tool.
Cancel leaves the current photo unchanged.

The conversion is approximate. RAW decoding disables tone boosts, highlight recovery,
lens correction and noise reduction, but retains the decoder's colour processing.
File profiles are converted to linear sRGB. These are not sensor-channel measurements.
The importer assumes zero remaining black offset, divides by the sampled film base,
and maps RGB densities independently to the selected film model, restoring its base
density. Monochrome uses the green density for all records. No measured scanner profile
is fitted or included. Uneven backlighting, flare and colour cross-talk remain uncorrected.
Nonpositive, nonfinite and out-of-range pixels, commonly the holder, are excluded and
painted black; they are not assigned invented densities. Crop away the holder and
check that image detail is not being excluded before accepting the conversion.

The positive is imported as a full-resolution 16-bit Display P3 TIFF in memory, with
**Normal** selected to avoid adding another film simulation. Existing exposure, colour
and export controls then apply to that positive. The original negative is unchanged.
Border sampling and film choice are baked into this positive; reimport the original to
change them. Crop edits remain editable and are saved with the photograph.

In **Crop**, drag each of the four circular handles independently. The selection must
remain convex and cannot cross itself. Leaving Crop (or pressing Return) straightens
the selected quadrilateral into a rectangle. Preview and full-resolution export use
the same normalized corners. **Four-Corner Crop** also enables this mode for ordinary
photos; choosing an aspect ratio returns to a rectangular crop. Reset Crop clears the
selection. Rotating or flipping clears four-corner selections to avoid reusing corners
from a different orientation. Undo and redo restore corner edits.
