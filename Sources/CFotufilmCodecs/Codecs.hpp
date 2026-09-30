// Shared pieces of the portable codecs: the raster a decoder hands to the colour stage, the Exif
// record, and the colour conversions. Nothing here is specific to one operating system.
#pragma once

#include "fotufilm_codecs.h"

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace ffc {

struct Failure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

enum class Samples { U8, U16, F32 };

/// How a raster's samples are to be read as light.
struct Encoding {
    enum Kind {
        /// No statement: sRGB for integer samples, linear Rec. 709 for floats.
        Unstated,
        /// The ICC profile in `icc`.
        Profile,
        /// Linear light in the primaries and white of `chromaticities`.
        Linear,
        /// A pure power `gamma` (decoding exponent) over `chromaticities`, as PNG gAMA/cHRM say;
        /// the sRGB curve when `gamma` is 0.
        Power,
    } kind = Unstated;
    std::vector<uint8_t> icc;
    /// rx, ry, gx, gy, bx, by, wx, wy.
    std::array<float, 8> chromaticities{0.64f, 0.33f, 0.30f, 0.60f, 0.15f, 0.06f,
                                        0.3127f, 0.3290f};
    float gamma = 1;
};

/// Pixels as a file stores them, before any colour or turn: interleaved, host byte order, one
/// to five channels (grey, grey+alpha, RGB, RGBA, CMYK, CMYK+alpha).
struct Raster {
    uint32_t width = 0, height = 0;
    int channels = 3;
    Samples samples = Samples::U8;
    /// Colour already multiplied by alpha (OpenEXR).
    bool associated = false;
    bool cmyk = false;
    std::vector<uint8_t> data;
    Encoding encoding;
    /// The Exif orientation still to apply, 1 for none.
    int orientation = 1;
};

/// What an Exif record says, as far as the decoders use it.
struct ExifFields {
    int orientation = 1;
    bool isDNG = false;
    /// A DNG's default crop within its active area: x, y, width, height; zero size when none.
    std::array<double, 4> crop{};
};

std::vector<uint8_t> readFile(const std::string &path);
void copyString(char *destination, size_t size, const std::string &value);

/// Reads an Exif TIFF structure (no "Exif\0\0" prefix) into `capture`'s fields.
ExifFields parseExif(const uint8_t *data, size_t length, ffc_capture &capture);
/// Keeps the structure `capture.exif` holds: the record an export carries.
void keepExif(const uint8_t *data, size_t length, ffc_capture &capture);
/// The record rewritten for an export: no orientation, pixel size, thumbnail, maker notes or
/// file-structure tags, and no GPS unless `keepLocation`.
std::vector<uint8_t> exportExif(const uint8_t *data, size_t length, bool keepLocation);
/// The ASCII records of the first directory (tag, text), for formats that carry only those.
std::vector<std::pair<uint16_t, std::string>> exifText(const uint8_t *data, size_t length);

Raster decodeJPEG(const std::string &path, ffc_capture &capture);
Raster decodePNG(const std::string &path, ffc_capture &capture);
Raster decodeTIFF(const std::string &path, ffc_capture &capture);
Raster decodeEXR(const std::string &path, ffc_capture &capture);
Raster decodeHEIF(const std::string &path, ffc_capture &capture);
/// Whether libheif has an HEVC encoder here.
bool heifEncodes();
/// A camera RAW straight to linear Rec. 2020 (`RawDecode.cpp`).
void decodeRaw(const std::string &path, uint32_t options, uint32_t longEdge, ffc_image &out);

/// Reusable row colour conversion. Owns its profile transform, never the source raster's data.
class SceneConverter {
public:
    SceneConverter(const Raster &raster, bool linearSamples);
    ~SceneConverter();
    void row(const void *source, uint32_t count, float *rgba) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/// The raster as associated linear Rec. 2020 RGBA, still in the file's orientation.
std::vector<float> sceneLinear(const Raster &raster, bool linearSamples);
/// Turns interleaved RGBA upright by an Exif orientation, updating the size.
void orient(std::vector<float> &rgba, uint32_t &width, uint32_t &height, int orientation);
/// Row-major 3x3 matrices for the colour arithmetic.
using Matrix = std::array<double, 9>;
Matrix multiply(const Matrix &a, const Matrix &b);
Matrix inverse(const Matrix &m);
/// Linear RGB to XYZ for primaries and white given as rx, ry, gx, gy, bx, by, wx, wy.
Matrix rgbToXYZ(const std::array<float, 8> &chromaticities);
/// Bradford adaptation from one white (xy) to another.
Matrix bradford(double sx, double sy, double dx, double dy);
/// XYZ (D65) to linear Rec. 2020.
Matrix xyzToRec2020();
/// A 3x3 matrix, row major, from linear RGB in these chromaticities to linear Rec. 2020 (D65),
/// with a Bradford adaptation when the white is not D65.
std::array<float, 9> toRec2020(const std::array<float, 8> &chromaticities);
/// The ICC profile every export carries: Display P3.
const std::vector<uint8_t> &displayP3Profile();

/// Runs `body(begin, end)` over row ranges on the machine's cores.
void parallelRows(uint32_t rows, const std::function<void(uint32_t, uint32_t)> &body);

void encodePNG(const std::string &path, const uint8_t *rgb, int bits, uint32_t width,
               uint32_t height, const std::vector<uint8_t> &exif);
void encodeJPEG(const std::string &path, const uint8_t *rgb, uint32_t width, uint32_t height,
                float quality, const std::vector<uint8_t> &exif);
void encodeTIFF(const std::string &path, const uint8_t *rgb, int bits, uint32_t width,
                uint32_t height, const std::vector<std::pair<uint16_t, std::string>> &text);
void encodeHEIF(const std::string &path, const uint8_t *rgb, uint32_t width, uint32_t height,
                float quality, const std::vector<uint8_t> &exif);

} // namespace ffc
