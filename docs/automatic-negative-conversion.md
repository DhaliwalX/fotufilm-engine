# Automatic scanned-negative conversion

Mac: **File → Import Scanned Negative… → Preview Positive**. Web: **More options →
Import Scanned Negative…**. No drawn reference is required. Review the preview,
then import the positive and refine its crop, colour and tone. Cancelling preserves
the current photograph. Both accept unadjusted TIFF, PNG, JPEG and supported camera RAW negatives.
Browser RAW-negative decoding preserves linear values without photographic
highlight reconstruction, DNG baseline exposure or scene spectral correction.

## Research and choice

[Lin and Tretter, *Digital Processing of Scanned Negatives*, PICS 1998, pp. 399–404](https://www.imaging.org/common/uploaded%20files/pdfs/Papers/1998/PICS-0-43/678.pdf)
propose automatic inversion using robust channel endpoints, soft clipping,
an inverse sigmoid, and scanner-dependent midtone adjustments. They tested 443
images and a second scanner. We independently implement the endpoint and contrast
parts. Their trained white-point prior and backlight heuristics are not enabled:
the publication does not supply portable parameters for our capture inputs.

[Tuijn, *Scanning Color Negatives*, CIC 1996, pp. 33–38](https://library.imaging.org/admin/apis/public/api/ist/website/downloadArticle/cic/4/1/art00010)
describes inverse characteristic curves and density-space colour correction.
These need measurements of the film/development/scanner combination. Installed
film-stock curves are not a substitute for that calibration. The existing explicit
`ScanDensityCalibration` API remains available for measured profiles.

## Our implementation

`AutomaticNegativeScan` analyses a preview no larger than 512 pixels per side. The
central 80% excludes ordinary edge holders; this is a fixed region, not automatic
frame detection. It excludes nonfinite, unbounded or wholly nonpositive RGB triplets and uses each
channel's fifth and ninety-fifth percentiles. Those values describe the **scene's
usable transmission range**, not a recovered physical film base.

`Stages/NegativeScan.h` owns the pixel operations. Colour-managed linear sRGB is
encoded with the sRGB transfer before inversion and endpoint normalization. The
normal range maps to 0.02…0.98, with continuous exponential tails outside it. The
symmetric inverse sigmoid uses exponent 0.6. These numerical defaults and the
exponential shoulder are our choices; they have not been fitted to a scanner corpus.
The result is decoded to linear RGB. No stock simulation, new grain or second
film development is applied.

Flat channels (less than 2% relative transmission range) receive a neutral midtone
instead of amplifying noise. The analysis reports limited range for review.
Colour-managed wide-gamut inputs can have a zero or negative channel in extended
sRGB. These channels are clamped individually to zero for this approximate inversion;
the other channels remain usable. Analysis uses the same clamping, so crossing a
gamut boundary does not create black speckles. This does not recover colour detail
clipped in the scan. Only wholly nonpositive, nonfinite or unbounded triplets render
black. The calibrated density API retains its stricter measurement validation.
Monochrome uses the green capture channel. Full-resolution processing reuses one analysis across all tiles;
zoom and preview resolution do not recompute the balance.

The same stage compiles to native CPU/Metal, Apple AOT CPU/Metal, and browser
WebAssembly SIMD/WebGPU. Browser colour-space adaptation also runs in Halide.
Analysis uses shared Swift, compiled to WASI in a worker. Browser conversion runs
in a cancellable worker with bounded 512×512 tiles and GPU-to-CPU fallback.
The imported positive remains floating point; export can deliver 16-bit TIFF.

This is an automatic starting point, not calibrated colour recovery. Coloured
lighting, nearly monochromatic subjects, clipped scans, thick holders or borders
inside the analysis region can bias it. Crop the source appropriately and review
colour balance. On Mac, sampling a clear border selects the existing stock-based
manual conversion; **Auto** restores the automatic method.

## Verification

```sh
FOTUFILM_SCAN_REFERENCE_DIRECTORY="$PWD/build/negative-reference" \
  swift test -c release --parallel --filter WebAutomaticNegativeRequestTests
bash tools/test-stages.sh
bash tools/build-negative-wasm.sh
bash tools/build-web-profile.sh
node tools/test-automatic-negative.mjs http://127.0.0.1:5173/
```

The browser check requires actual WebGPU and compares synthetic colour and
monochrome samples to native output, across a tile boundary, before display
encoding. It also checks cancellation and TIFF import through the dialog.
Synthetic checks verify implementation and precision; they do not establish
photographic accuracy across real scanners and films.
