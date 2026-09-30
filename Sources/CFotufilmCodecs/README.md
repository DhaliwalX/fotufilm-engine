# Portable image codecs

`ffc_decode` opens scene-linear Rec.2020 RGBA; `ffc_encode` writes Display P3. Apple hosts keep
their ImageIO/Core Image path. The sources compile empty on Apple unless `FFC_PORTABLE_CODECS`
is explicitly set for the portable codec host checks.

Hosts which already have ordinary image codecs can link only `RawDecode.cpp`, `Colour.cpp`,
`Exif.cpp`, and `ImageMemory.cpp`, with LibRaw and lcms2. Call `ffc_decode_raw` with explicit file,
sensor-pixel and working-memory limits, then release its result with `ffc_image_free`. The input
is identified from its contents, so private copies need no filename extension. An unsupported
status means LibRaw did not recognize the file; a known RAW import must report that failure
instead of silently replacing the sensor image with an embedded preview.

The memory check precedes unpacking and demosaicing. Its conservative estimate covers the input,
full sensor, working camera image, demosaic scratch, processed RGB16 and delivered float image.
It is an admission estimate, not a process-wide allocation limit. LibRaw additionally receives a
RAW allocation ceiling. Hosts must budget their existing images and subsequent rendering too.
The long edge bounds the returned raster, while separate source dimensions retain the upright
default crop. Half-size demosaicing is used only when there are still at least two decoded pixels
per requested preview pixel. Final preview reduction is bilinear in linear light.

RAW development uses as-shot white balance, no automatic brightness, no dynamic white-level
adjustment, no tone curve or sharpening, and quality-3 demosaicing (AHD for Bayer, three passes
for X-Trans). Scene imports blend clipped
highlights; scanned negatives preserve them without reconstruction. The normalized camera-green
multiplier is undone in float, preserving sensor headroom above diffuse white. Only scene imports
apply an explicit DNG baseline exposure. DNG matrices and default crops are read from the file.
Apple's demosaicing, per-camera profiles, non-DNG exposure offsets, lens correction and highlight
recovery can produce different results. This is not a pixel-identical Core Image decoder.

Run `tools/test-raw-codec.sh` on macOS or Linux with LibRaw 0.22.2, lcms2, clang++ and Node installed.
It generates project-authored DNGs, then tests the C boundary under AddressSanitizer and UBSan:
orientation/default crops, linear preview sampling, Bayer and linear-DNG radiance, baseline
exposure, highlight headroom, precision, metadata, and malformed/over-budget requests. Generated
images and executables stay in ignored `build/` output. It does not launch a device or simulator.
Pass `--cameras` to also download four checksum-pinned CC0 samples from raw.pixls.us (about 80 MB)
and check full/preview geometry for Fujifilm SuperCCD and X-Trans, Nikon NEF and Canon CR3. Camera
files remain local test inputs. The default CI check requires only the synthetic fixtures.

`ffc_decode_tiff` provides bounded processed-TIFF import when ImageIO is unavailable. Link
`TIFFImport.cpp`, `Colour.cpp` and `ImageMemory.cpp` with libtiff 4.7 or newer and lcms2. Try the RAW
entry point first: only `FFC_RAW_UNSUPPORTED` permits trying TIFF. A recognized RAW failure must
remain an error. The TIFF entry point also rejects RAW markers in image and SubIFD directories,
including a normal thumbnail which points to a CFA image.

The TIFF reader converts unsigned 1/2/4/8/16/32-bit and float16/32/64 samples into float32
working pixels using embedded RGB, grayscale or CMYK profiles and all eight orientations. It reads the first image only. Strips,
tiles, separate colour planes, palette images, classic TIFF and BigTIFF are supported. Available
compression depends on the linked libtiff build; JPEG YCbCr requires its JPEG codec. Unprofiled
CMYK, other YCbCr layouts, Lab and other unsupported encodings report an error. Integer images
without profiles use sRGB; untagged floats use linear sRGB. Colour is unassociated before
nonlinear profile conversion and associated again in linear light. Negative values and float
headroom are retained. Invalid profiles, nonfinite pixels and alpha outside 0–1 are errors.

Callers set file-size, pixel-count and working-memory limits. libtiff receives one third of the
working budget as its per-handle single/cumulative allocation ceiling, with memory mapping off.
Admission separately accounts for a strip or tile-band cache, output pixels, row scratch and
conservative profile workspace. This is not a process-wide hard allocation limit; callers still
budget their retained source and rendering allocations. A preview allocates only its delivered
float image and required rows, never a full-size float intermediate. It may still decompress a
whole strip or tile band. Reduction uses bilinear sampling in linear premultiplied light. Basic
capture/lens fields are retained; the API does not copy the entire TIFF into an opaque EXIF blob.

Run `tools/test-tiff-codec.sh` with libtiff 4.7+, lcms2 and clang++. Its project-authored fixtures
exercise precision, colour, orientation, alpha, metadata, RAW rejection, malformed files and
memory admission under AddressSanitizer and UBSan. On macOS it additionally compares ordinary
RGB/alpha TIFFs, classic orientations and half/float images against ImageIO/Core Image, and
writes a side-by-side colour preview into ignored build output. Unusual layouts are checked
against source values: Core Image can ignore BigTIFF orientation, invert some white-is-zero
grayscale depths differently, discard extra-channel alpha, or reject 64-bit/palette TIFFs.
JPEG chroma upsampling can also differ. Support is not a claim of pixel-identical decoding for
every TIFF layout. No device or simulator is launched.
