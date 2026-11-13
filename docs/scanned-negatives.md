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
crosstalk correction, monochrome record mapping and usable-range mask. Set it as `FotufilmEngine.Options.scanReading`
and hand the print span (`stage = .print`) linear scan RGB in place of densities: the kernels read
each sample as `density(of:)` does and print the samples it cannot place black. `convert` reads a
whole buffer in Swift, for reference. Neither alters the source scan nor fits a scanner profile.
`NegativeScanPreparation` runs the kernels that divide a light frame out of a scan and read a
scan without a film (`PlainNegativeScan`).

A camera or scanner channel is broader than the dye it is read for, so a red channel also sees
some of the magenta and yellow dyes; read one channel per record, the records share each other's
density and colours come out muted. The `crosstalk` strength (0 to 1, `NegativeScanCrosstalk`)
reads each record from all three channels instead. The full correction inverts the 3×3 matrix of
each channel's density of each of the film's dyes under the scan's light, linearised about
neutral. `scanLight` names that light: `white` models a camera or scanner under white light, whose
linear Rec. 2020 channels see the spectrum as the Rec. 2020 colour-matching functions do under a
flat lamp; `rgb` models one exposure under each of a red, green and blue LED merged into a scan,
Gaussian bands peaking at 625, 522 and 455 nm, which leaves little to undo. Each row is then scaled
so the frame's densest end, which its balance takes as a neutral highlight, reads as it did, so the
frame is timed and balanced as before (rows summing to one where the frame gives none); lower
strengths blend toward one channel per record. A reading without a film uses a typical colour
negative's dyes. The print kernels take the weights in `FOTUFILM_CONFIG_SCAN_CROSSTALK` and clamp
densities to `NegativeInterchange.range`.

That is the first reading, which an edit saved with it keeps (`WebNativeEdit.Negative.reading`
absent). Its white-light model is not fitted to a camera: on camera scans under white light it
amplifies red against green about 1.6 times at full strength, so warm areas the frame's balance
leaves slightly warm turn red; values around 0.3 to 0.5 separate skies and foliage with little of
that.

### The current reading

A new scan's edit is made with the current reading (`reading` 2), which every surface resolves
in one place (`WebNativeEdit.Negative.balance`, `.plain` and `.strayLight`):

- **The scan's light and camera.** `NegativeScanSetup` is what the scan was made with and under:
  a white LED panel, a phone or tablet screen, a halogen lamp or red, green and blue LEDs, seen
  by a generic camera, a film scanner, or a camera with measured channels. A measured camera is
  taken only where the file's decoder says the matrix it mixed the camera's channels with
  (`NegativeScanCapture`), since decoders differ and a dense negative's blue follows the matrix
  closely. `NegativeScanModel` carries the film's record densities to its spectral density, as
  the print stage does, and through each channel of that setup.
- **The fit.** The weights each record reads from the scan's three channel densities are the
  least squares on the film's own greys and the colours about them (`NegativeScanModel.weights`),
  so the densities read are the ones that made the scan: within 0.025 of a density on the
  greys and 0.035 on the colours in the model, under every lamp and camera. Colour Separation
  (`crosstalk`) runs from one channel per record, scaled to hold the greys, to the full fit.
- **What the model knows.** A measured camera, a film scanner's bands and LEDs that light one
  channel each say how much density a channel reads of a dye (`NegativeScanSetup.knowsScale`).
  A camera nobody measured is modelled with the median spectral sensitivity of the bundled Bayer
  CMOS cameras (`NegativeScanSetup.genericCMOSProfile`), balanced on the lamp and mapped to
  Rec. 2020: that predicts dye cross-talk closely enough for full Colour Separation by default,
  though an unmeasured lamp's red end still leaves overall channel scale uncertain, so the
  reading keeps the scan's own density of green as the film's.
- **Stray light.** `flare` is the scan's stray light as a share of the frame's average light, or
  is left to be measured from the holder (`ApproximateNegativeScan.strayLight`): the holder is
  taken to be in view only where the darkest twentieth of the scan lies around its edge, is even
  to within a stop and is a stop darker than any film in the scan's middle. It is taken off each
  sample and the clear film before their densities (`FOTUFILM_CONFIG_SCAN_FLARE`), and the frame's
  tones are read net of it.
- **Balance.** `balance` is `frame`, `roll` or `none`. The frame's neutral, one picked on it
  (`neutral`) or else its densest end, or its roll's, is put on the film's own grey scale. Two
  things move a neutral off it: how steep each record reads, which the film's age and
  development and the scan's own light and camera set, and the scene's light, which is one
  exposure at every tone. One neutral cannot tell them apart. A roll's tonal steps, or a
  regularized estimate from the frame's own tonal steps (`ApproximateNegativeScan.frameContrastRange`,
  `0.75...1.35`) when no roll contrast is measured, first match red's and blue's steepness to
  green's; the neutral then adds a log exposure to red and blue, as a printer's filtration does,
  so each record moves along the film's own characteristic curve (`ApproximateNegativeScan.balance`,
  `FOTUFILM_CONFIG_SCAN_BALANCE`): nothing at the clear film, more through the toe, one density
  on the straight line.
- **The clear film and the holder.** Until clear film is picked it is estimated: the brightest
  of the scan, or where the scan shows its bare light through sprocket holes or around a strip,
  the film's base under that light (`ApproximateNegativeScan.estimatedFilmBase`). A holder the
  scan shows is left out of what the frame measures, so the print is timed on the picture's
  highlights and not on the holder (`ApproximateNegativeScan.withoutHolder`), and prints black.
  The holder ends where the fewest pixels lie between it and the densest film in the scan's
  middle (`ApproximateNegativeScan.holder`).
- **A roll's contrast.** A frame's tonal steps, where light falls off across a surface or a
  shadow lies on it, change every record's exposure alike, so the rises of red and blue per unit
  of green across them say how steep the roll's records read against each other
  (`ApproximateNegativeScan.tonalSlopes`). With six frames' steps or more a roll's records are
  made as steep against green as the film's own across `0.7...1.5`, replacing the single-frame
  regularized estimate on every frame balanced on its frame or roll.
- **Without a film.** Normal's weights are fitted on an ordinary orange-masked colour negative
  through the same setup. Its light follows a negative's curve with a toe, density growing as
  gamma times the logarithm of one plus the exposure over the toe's, so the clear film is no
  exposure and reads black. Once a roll's contrast is measured (or from the frame's own
  regularized tonal steps when readable), the records are made as steep as each other and the
  neutral is balanced by each channel's light; where no tonal steps are readable, red's and
  blue's densities are scaled onto green's at the frame's neutral (`PlainNegativeScan`). It takes
  the scan's stray light off the same way.

Three further steps were measured and left out. Reading a camera's own channels before its
decoder's matrix read the model's colours worse, not better, and carries more of the scan's
noise. A table solving the three dyes exactly gains no more than the fit's own few hundredths of
a density. Keeping the fine detail on one channel per record lowers fine-detail noise by a few
percent on real camera scans, for a spatial filter in every kernel. A neutral estimated jointly
across the channels was no better than each channel's densest end on real frames.

The browser profile protocol's film request takes
`negative: {border, denseEnd, light, crosstalk, scanLight}`, and for the current reading also
`reading`, `camera`, `balance`, `neutral`, `roll`, `strayLight` (the stray light the browser
resolved, as linear scan RGB) and `source` (what the RAW decoder says of the scan's camera,
white and matrix). The browser's builder carries no measured cameras, so the request brings the
record of the camera its scan names (`cameraProfile`). The first reading's fields are
the clear film as three linear scan values, the framed picture's densest end
(`ApproximateNegativeScan.denseEnd`, or nothing for a frame too small to read), the edit's
`ev`, `temperature` and `tint`, which the enlarger or the scan takes, and the crosstalk correction
and the light it is computed for (0 and `white` when absent). It prepares the print
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
its clear film base. Each film's base is predicted from its spectral model through the scan's
`NegativeScanSetup` — lamp spectrum, measured or median CMOS camera channels and RAW decoding
matrix (`NegativeScanModel.clear`) — or as a lamp-balanced colorimetric scan when no setup is
supplied. `read(preview:)` finds the base in a linear Rec.2020 preview as the thinnest density
plateau. When a neutral light shows past the film's edge with an orange base under it, the base
is read against that light. `suggest(_:)` fits each scan's residual colour saturation around the
setup's prediction and returns suggestions with a likelihood share.

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

## Trichromatic scans

A trichromatic scan photographs each frame three times, under red, green and blue light, so
each exposure records one dye layer without the camera's broad channels mixing them. **Import
Trichromatic Scan…** merges the exposures into one scan per frame, then opens each as a scanned
negative.

- **Light.** Each exposure's light is measured from its colour. Under one narrow light every
  pixel is that light's colour scaled by the film's transmittance, whatever the camera's
  balance or matrix did, so that scale is the exposure's layer (`TrichromaticScan`).
- **Decoding.** Camera RAW files are decoded through a fixed daylight balance rather than
  the shot's, and at half size, since each colour has only a quarter of the photosites. Each
  exposure is decoded once, several side by side, and only its layer is kept until the
  exposures are grouped.
- **Blank exposures.** Exposures of no picture are left out: a light frame, or the film's
  leader.
- **White light.** White light through a colour negative's orange mask is mostly red too, but
  its colour changes across the picture with the dyes, where a red light's holds: such
  exposures are left out.
- **Repeats.** An exposure that a later one under the same light repeats, the same film in the
  same place, is left out for the later one, as a frame retaken.
- **Grouping.** The remaining exposures are grouped into frames in the order of their names.
  They may come frame by frame, each frame's three lights in any order, or in whole passes of a
  roll, one light at a time.
  Passes of unequal length stop the merge with a count of each light.
- **Registration.** Green and blue are lined up with red by an affine fit. Phase correlation
  runs on patches across the middle of the frame, and patches that disagree, such as a speck
  on one layer, are dropped. Exposures of different frames share too little detail to line up
  and are not merged. Layers that line up only loosely, as film that bowed between exposures
  does, are merged and named, since their colours may fringe.
- **The file.** The three layers are merged into an untagged 16-bit TIFF, each scaled so its
  clear end sits near the top of the range. The desktop saves it beside the red exposure as
  `<name>-rgb.tif`; the browser downloads it; iOS keeps it on the shelf.

A merged scan has the same balance under each light, so its film base shows no orange mask and
film suggestions read it as black-and-white; choose the film yourself.

```sh
swift run -c release fotufilm --merge-trichromatic exposures/*.ARW
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
Each directory of the folder is a roll; a subfolder is a roll of its own. Opening one photo from
the library brings every picture of its roll into the strip below the photograph, in the
library's order; choosing several opens just those. A frame opened for the first time starts
from the film, film settings, clear film, light frame and roll balance of its roll's frame
edited last, as frames of one roll share them.

The **Roll** panel works on the whole roll. **Measure Roll** develops every frame of the roll in
the strip and reads each one's densest end, its highlights, and the rises across its tonal
steps. The roll's colour is the median over its frames of each end's red and blue density per
unit of its green; a frame filled by one colour, such as a sunset, moves a median little. What
the roll measured is kept with each frame's edit and travels with Copy Settings; the shown
frame's change can be undone. A frame whose **Balance** is **Roll** is balanced on the roll's
colour instead of its own highlights, still timed on its own highlights so a darker frame does
not print darker; **Frame** balances it on its own, and **None** leaves the film as it reads.
With six frames' tonal steps or more, the roll's contrast is used on every frame balanced on
its frame or its roll. Measure again after cropping frames or adding them to the roll. Fewer
than two frames with readable highlights cannot be measured. A roll shot under several lights
is better balanced frame by frame. On an edit saved with the first reading, measuring the roll
balances every frame on it, and **Balance This Frame Alone** and **Balance Every Frame Alone**
return one frame or the whole roll to their own colour.

With **Normal**, the scan is read without a film and edited as a plain positive photograph.
Each channel's density above the clear base is balanced on the frame's neutral and taken back
to scene light along a negative of gamma 0.6 with a toe, the densest end landing on diffuse
white and the clear film on black (`PlainNegativeScan`); an edit saved with the first reading
runs along a straight line. Every photo control then applies; no print simulation does.

Those densities then take the print exactly as a simulated negative does: every output
medium, lamp, screen conversion and print frame applies, and an enlarged paper is timed
to the negative's density, as a lab times each frame. Development and grain act before the
negative existed and do not apply. Crop, rotation and straightening are the editor's own and
are saved with the edit; the scan itself is never changed.

The light controls act on the print (`NegativeScanPrint.printing`). On an enlarged paper,
exposure and white balance are the enlarger's (`PrinterMatching`): exposure scales printing light
through the stock-and-paper sensitivity curve, and warmth and tint solve YMC filtration trims so
mid-grey lands on the target warmth and tint through the paper's actual dyes. On a cinema release
print film, exposure and white balance adjust additive `PrinterLights` before the print stock's
characteristic curves. On Digital Reference and Lab Scan, exposure and white balance adjust
pre-curve `screenExposureEV` and `screenCMY` density trims (`SpectralRuntime.screenCMY`). Whatever
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
