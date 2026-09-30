# Portable image codecs

`ffc_decode` opens scene-linear Rec.2020 RGBA; `ffc_encode` writes Display P3. Apple hosts keep
their ImageIO/Core Image path. The sources compile empty on Apple unless `FFC_PORTABLE_CODECS`
is explicitly set for the RAW host check.

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
adjustment, no tone curve or sharpening, and AHD demosaicing. Scene imports blend clipped
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
