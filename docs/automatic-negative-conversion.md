# Automatic scanned-negative conversion

The native apps convert a scanned negative into a positive automatically, without a drawn
reference. Review the preview, then import the positive and refine its crop, colour and tone.
They accept unadjusted TIFF, PNG, JPEG and supported camera RAW negatives. The desktop and
browser editors read a scan as a film instead ([scanned negatives](scanned-negatives.md)).

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
symmetric inverse sigmoid uses exponent 0.6, which is also its slope at mid-grey;
These numerical defaults and the
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

The same stage compiles to native CPU/Metal and Apple AOT CPU/Metal. The imported positive
remains floating point; export can deliver 16-bit TIFF.

This is an automatic starting point, not calibrated colour recovery. Coloured
lighting, nearly monochromatic subjects, clipped scans, thick holders or borders
inside the analysis region can bias it. Crop the source appropriately and review
colour balance. On Mac, sampling a clear border selects the existing stock-based
manual conversion; **Auto** restores the automatic method.

## Verification

```sh
swift test -c release --parallel --filter AutomaticNegativeScanTests
bash tools/test-stages.sh
```

Synthetic checks verify implementation and precision; they do not establish
photographic accuracy across real scanners and films.
