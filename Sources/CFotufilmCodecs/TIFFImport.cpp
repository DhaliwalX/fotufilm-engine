// Bounded TIFF import for hosts without ImageIO. No full-size float preview intermediate.
#if !defined(__APPLE__) || defined(FFC_PORTABLE_CODECS)
#include "Codecs.hpp"
#include <tiffio.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <set>

namespace ffc {
namespace {
struct UnsupportedTIFF : Failure { using Failure::Failure; };
struct Diagnostics {
    char text[512]{};
    static int error(TIFF *, void *data, const char *, const char *format, va_list args) {
        std::vsnprintf(static_cast<Diagnostics *>(data)->text, sizeof text, format, args);
        return 1;
    }
    static int warning(TIFF *, void *, const char *, const char *, va_list) { return 1; }
    void check() { if (text[0]) throw Failure(std::string("TIFF: ") + text); }
};
using TIFFOwner = std::unique_ptr<TIFF, decltype(&TIFFClose)>;

uint64_t fileSizeAndKind(const char *path, uint64_t limit) {
    std::unique_ptr<FILE, decltype(&std::fclose)> file(std::fopen(path, "rb"), std::fclose);
    if (!file) throw Failure("Could not open the TIFF file.");
    if (std::fseek(file.get(), 0, SEEK_END) || std::ftell(file.get()) < 0) throw Failure("Could not measure the TIFF file.");
    const uint64_t size = uint64_t(std::ftell(file.get()));
    if (size > limit) throw Failure("The TIFF exceeds the file-size limit.");
    if (std::fseek(file.get(), 0, SEEK_SET)) throw Failure("Could not read the TIFF file.");
    uint8_t head[16]{};
    const size_t read = std::fread(head, 1, sizeof head, file.get());
    const bool little = read >= 4 && head[0] == 'I' && head[1] == 'I' && (head[2] == 42 || head[2] == 43) && !head[3];
    const bool big = read >= 4 && head[0] == 'M' && head[1] == 'M' && !head[2] && (head[3] == 42 || head[3] == 43);
    if (!little && !big) throw UnsupportedTIFF("This file is not a TIFF image.");
    if (read >= 12 && head[8] == 'C' && head[9] == 'R' && head[10] == 2 && head[11] == 0)
        throw UnsupportedTIFF("A camera RAW TIFF must be opened by the RAW decoder.");
    return size;
}

// RAW may live behind a thumbnail. Never mistake a DNG/CFA SubIFD for an ordinary TIFF page.
void rejectRawDirectories(TIFF *tiff, Diagnostics &errors) {
    const toff_t first = TIFFCurrentDirOffset(tiff);
    std::vector<toff_t> pending{first};
    std::set<toff_t> visited;
    for (size_t at = 0; at < pending.size(); ++at) {
        const toff_t offset = pending[at];
        if (!visited.insert(offset).second) continue;
        if (visited.size() > 256 || pending.size() > 512) throw Failure("The TIFF has too many image directories.");
        if (!TIFFSetSubDirectory(tiff, offset)) throw Failure("A TIFF image directory could not be read.");
        errors.check();
        uint16_t photometric = 0; uint8_t *version = nullptr; uint16_t *cfa = nullptr;
        TIFFGetField(tiff, TIFFTAG_PHOTOMETRIC, &photometric);
        if (photometric == PHOTOMETRIC_CFA || photometric == 34892 /* LinearRaw */
            || TIFFGetField(tiff, TIFFTAG_DNGVERSION, &version)
            || TIFFGetField(tiff, TIFFTAG_CFAREPEATPATTERNDIM, &cfa))
            throw UnsupportedTIFF("A camera RAW TIFF must be opened by the RAW decoder.");
        uint16_t count = 0; uint64_t *offsets = nullptr;
        if (TIFFGetField(tiff, TIFFTAG_SUBIFD, &count, &offsets)) {
            if (count > 256) throw Failure("The TIFF has too many subimages.");
            for (uint16_t i = 0; i < count; ++i) if (offsets[i]) pending.push_back(offsets[i]);
        }
        if (!TIFFLastDirectory(tiff)) {
            if (!TIFFReadDirectory(tiff)) throw Failure("A TIFF image directory could not be read.");
            pending.push_back(TIFFCurrentDirOffset(tiff));
        }
    }
    if (!TIFFSetSubDirectory(tiff, first)) throw Failure("The first TIFF image could not be read.");
    errors.check();
}

struct Rows {
    TIFF *tiff;
    uint32_t width = 0, height = 0, blockWidth = 0, blockHeight = 0, across = 1;
    uint16_t bits = 0, spp = 0, sampleFormat = 0, planar = 0, photometric = 0, orientation = 1;
    int colours = 0, alphaIndex = -1;
    bool associated = false, tiled = false, palette = false;
    uint16_t *map[3]{};
    uint64_t blockBytes = 0, rowBytes = 0;
    uint32_t currentBand = UINT32_MAX;
    std::vector<int> planes;
    std::vector<std::vector<uint8_t>> blocks;
    Raster layout;

    explicit Rows(TIFF *value) : tiff(value) {
        TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
        TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_BITSPERSAMPLE, &bits);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLESPERPIXEL, &spp);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLEFORMAT, &sampleFormat);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_PLANARCONFIG, &planar);
        TIFFGetFieldDefaulted(tiff, TIFFTAG_ORIENTATION, &orientation);
        if (!TIFFGetField(tiff, TIFFTAG_PHOTOMETRIC, &photometric))
            throw Failure("The TIFF has no photometric interpretation.");
        if (!width || !height || width > 32768 || height > 32768 || spp > 64 || !spp
            || (planar != PLANARCONFIG_CONTIG && planar != PLANARCONFIG_SEPARATE) || orientation < 1 || orientation > 8)
            throw Failure("The TIFF has invalid image dimensions or layout.");
        if (photometric == PHOTOMETRIC_YCBCR) {
            uint16_t compression = 0;
            TIFFGetField(tiff, TIFFTAG_COMPRESSION, &compression);
            if (compression != COMPRESSION_JPEG || planar != PLANARCONFIG_CONTIG || bits != 8 || spp != 3
                || !TIFFSetField(tiff, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB))
                throw Failure("Only JPEG-compressed 8-bit YCbCr TIFF images are supported.");
            photometric = PHOTOMETRIC_RGB;
        }
        if (photometric == PHOTOMETRIC_RGB) colours = 3;
        else if (photometric == PHOTOMETRIC_MINISBLACK || photometric == PHOTOMETRIC_MINISWHITE) colours = 1;
        else if (photometric == PHOTOMETRIC_SEPARATED) {
            uint16_t inkset = INKSET_CMYK;
            TIFFGetFieldDefaulted(tiff, TIFFTAG_INKSET, &inkset);
            if (inkset != INKSET_CMYK) throw Failure("Only CMYK separated TIFF images are supported.");
            colours = 4; layout.cmyk = true;
        } else if (photometric == PHOTOMETRIC_PALETTE) {
            palette = true; colours = 3;
            if (spp != 1 || bits > 16 || !TIFFGetField(tiff, TIFFTAG_COLORMAP, &map[0], &map[1], &map[2]))
                throw Failure("The TIFF colour map is invalid.");
        } else throw Failure("This TIFF colour layout is not supported.");
        const bool integer = sampleFormat == SAMPLEFORMAT_UINT && (bits == 1 || bits == 2 || bits == 4 || bits == 8 || bits == 16 || bits == 32);
        const bool floating = sampleFormat == SAMPLEFORMAT_IEEEFP && (bits == 16 || bits == 32 || bits == 64);
        if ((!integer && !floating) || (palette && !integer) || (!palette && spp < colours))
            throw Failure("This TIFF sample format is not supported.");
        uint16_t extraCount = 0; uint16_t *extras = nullptr;
        TIFFGetField(tiff, TIFFTAG_EXTRASAMPLES, &extraCount, &extras);
        if (extraCount > spp - (palette ? 1 : colours)) throw Failure("The TIFF extra-sample layout is invalid.");
        for (uint16_t i = 0; i < extraCount; ++i) {
            if (extras[i] != EXTRASAMPLE_ASSOCALPHA && extras[i] != EXTRASAMPLE_UNASSALPHA) continue;
            if (alphaIndex >= 0) throw Failure("The TIFF has multiple alpha channels.");
            alphaIndex = colours + i; associated = extras[i] == EXTRASAMPLE_ASSOCALPHA;
        }
        layout.width = width; layout.height = 1; layout.samples = Samples::F32;
        layout.channels = colours + (alphaIndex >= 0 ? 1 : 0); layout.associated = associated;
        if (integer) { layout.encoding.kind = Encoding::Power; layout.encoding.gamma = 0; }
        if (planar == PLANARCONFIG_CONTIG) planes.push_back(0);
        else {
            for (int i = 0; i < (palette ? 1 : colours); ++i) planes.push_back(i);
            if (alphaIndex >= 0) planes.push_back(alphaIndex);
        }
        tiled = TIFFIsTiled(tiff);
        if (tiled) {
            TIFFGetField(tiff, TIFFTAG_TILEWIDTH, &blockWidth);
            TIFFGetField(tiff, TIFFTAG_TILELENGTH, &blockHeight);
            if (!blockWidth || !blockHeight) throw Failure("The TIFF tile size is invalid.");
            across = (width + uint64_t(blockWidth) - 1) / blockWidth;
            blockBytes = TIFFTileSize64(tiff); rowBytes = TIFFTileRowSize64(tiff);
        } else {
            blockWidth = width;
            TIFFGetFieldDefaulted(tiff, TIFFTAG_ROWSPERSTRIP, &blockHeight);
            blockHeight = std::min(blockHeight, height);
            blockBytes = TIFFStripSize64(tiff); rowBytes = TIFFScanlineSize64(tiff);
        }
        if (!blockBytes || !rowBytes || !blockHeight || blockBytes > uint64_t(std::numeric_limits<tmsize_t>::max()))
            throw Failure("The TIFF decode block size is invalid.");
        uint32_t length = 0; void *profile = nullptr;
        if (TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &length, &profile)) {
            if (!profile || !length || length > (16u << 20)) throw Failure("The TIFF colour profile is invalid or too large.");
            layout.encoding.kind = Encoding::Profile;
            layout.encoding.icc.assign(static_cast<const uint8_t *>(profile), static_cast<const uint8_t *>(profile) + length);
        }
    }
    uint64_t cacheBytes() const {
        const uint64_t count = uint64_t(across) * planes.size();
        if (blockBytes > std::numeric_limits<uint64_t>::max() / count) throw Failure("The TIFF blocks are too large.");
        return count * blockBytes;
    }
    void load(uint32_t y) {
        const uint32_t band = y / blockHeight;
        if (band == currentBand) return;
        blocks.resize(size_t(across) * planes.size());
        for (size_t p = 0; p < planes.size(); ++p) for (uint32_t x = 0; x < across; ++x) {
            auto &block = blocks[p * across + x]; block.resize(size_t(blockBytes));
            const auto index = tiled ? TIFFComputeTile(tiff, x * blockWidth, band * blockHeight, 0, uint16_t(planes[p]))
                : TIFFComputeStrip(tiff, band * blockHeight, uint16_t(planes[p]));
            const uint64_t needed = tiled ? blockBytes : rowBytes * std::min(blockHeight, height - band * blockHeight);
            const tmsize_t read = tiled ? TIFFReadEncodedTile(tiff, index, block.data(), tmsize_t(needed))
                : TIFFReadEncodedStrip(tiff, index, block.data(), tmsize_t(needed));
            if (read < 0 || uint64_t(read) != needed) throw Failure("A TIFF image block is incomplete.");
        }
        currentBand = band;
    }
    double value(const uint8_t *row, uint64_t sample) const {
        if (bits < 8) {
            const uint64_t bit = sample * bits;
            return (row[bit / 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1);
        }
        const uint8_t *at = row + sample * (bits / 8);
        if (sampleFormat == SAMPLEFORMAT_UINT) {
            if (bits == 8) return *at;
            if (bits == 16) { uint16_t v; std::memcpy(&v, at, 2); return v; }
            uint32_t v; std::memcpy(&v, at, 4); return v;
        }
        if (bits == 16) {
            uint16_t h; std::memcpy(&h, at, 2);
            const int exponent = (h >> 10) & 31, fraction = h & 1023;
            const double sign = h & 0x8000 ? -1 : 1;
            if (exponent == 31) return fraction ? NAN : sign * INFINITY;
            return sign * (exponent ? std::ldexp(1 + fraction / 1024.0, exponent - 15) : std::ldexp(double(fraction), -24));
        }
        if (bits == 32) { float v; std::memcpy(&v, at, 4); return v; }
        double v; std::memcpy(&v, at, 8); return v;
    }
    void row(uint32_t y, std::vector<float> &result) {
        load(y); result.resize(size_t(width) * layout.channels);
        const double scale = sampleFormat == SAMPLEFORMAT_UINT ? 1.0 / ((uint64_t(1) << bits) - 1) : 1;
        for (uint32_t x = 0; x < width; ++x) {
            const uint32_t tile = x / blockWidth, localX = x % blockWidth;
            auto read = [&](int channel) {
                const int physical = channel == colours && alphaIndex >= 0 ? alphaIndex : channel;
                const size_t plane = planar == PLANARCONFIG_CONTIG ? 0 : channel;
                const uint8_t *line = blocks[plane * across + tile].data() + (y % blockHeight) * rowBytes;
                return value(line, uint64_t(localX) * (planar == PLANARCONFIG_CONTIG ? spp : 1)
                    + (planar == PLANARCONFIG_CONTIG ? physical : 0));
            };
            float *out = result.data() + size_t(x) * layout.channels;
            if (palette) {
                const size_t index = size_t(read(0));
                for (int c = 0; c < 3; ++c) out[c] = map[c][index] / 65535.0f;
            } else {
                for (int c = 0; c < layout.channels; ++c) out[c] = float(read(c) * scale);
                if (photometric == PHOTOMETRIC_MINISWHITE)
                    out[0] = (associated && alphaIndex >= 0 ? out[colours] : 1) - out[0];
            }
        }
    }
};

void basicCapture(TIFF *tiff, ffc_capture &capture) {
    auto text = [&](uint32_t tag, char *out, size_t size) {
        char *value = nullptr;
        if (TIFFGetField(tiff, tag, &value) && value) {
            size_t count = 0; while (count + 1 < size && value[count]) ++count;
            std::memcpy(out, value, count); out[count] = 0;
        }
    };
    text(TIFFTAG_MAKE, capture.make, sizeof capture.make);
    text(TIFFTAG_MODEL, capture.model, sizeof capture.model);
    uint64_t offset = 0;
    if (TIFFGetField(tiff, TIFFTAG_EXIFIFD, &offset) && offset && TIFFReadEXIFDirectory(tiff, offset)) {
        text(EXIFTAG_LENSMAKE, capture.lens_make, sizeof capture.lens_make);
        text(EXIFTAG_LENSMODEL, capture.lens_model, sizeof capture.lens_model);
        TIFFGetField(tiff, EXIFTAG_FOCALLENGTH, &capture.focal_length);
        TIFFGetField(tiff, EXIFTAG_FNUMBER, &capture.f_number);
        uint16_t focal35 = 0;
        if (TIFFGetField(tiff, EXIFTAG_FOCALLENGTHIN35MMFILM, &focal35)) capture.focal_length_35mm = focal35;
    }
}

void importTIFF(const char *path, uint32_t options, uint32_t longEdge, const ffc_tiff_limits &limits,
                ffc_image &out, uint32_t &sourceWidth, uint32_t &sourceHeight) {
    fileSizeAndKind(path, limits.max_file_bytes);
    Diagnostics errors;
    std::unique_ptr<TIFFOpenOptions, decltype(&TIFFOpenOptionsFree)> settings(TIFFOpenOptionsAlloc(), TIFFOpenOptionsFree);
    if (!settings) throw std::bad_alloc();
    const uint64_t libraryBudget = std::min(limits.max_working_bytes / 3, uint64_t(std::numeric_limits<tmsize_t>::max()));
    if (!libraryBudget) throw Failure("There is not enough memory to open this TIFF.");
    TIFFOpenOptionsSetMaxSingleMemAlloc(settings.get(), tmsize_t(libraryBudget));
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(settings.get(), tmsize_t(libraryBudget));
    TIFFOpenOptionsSetErrorHandlerExtR(settings.get(), Diagnostics::error, &errors);
    TIFFOpenOptionsSetWarningHandlerExtR(settings.get(), Diagnostics::warning, &errors);
    TIFFOwner tiff(TIFFOpenExt(path, "rm", settings.get()), TIFFClose);
    errors.check();
    if (!tiff) throw Failure("The TIFF could not be opened.");
    rejectRawDirectories(tiff.get(), errors);
    Rows rows(tiff.get()); errors.check();
    if (uint64_t(rows.width) * rows.height > limits.max_pixels) throw Failure("The TIFF exceeds the pixel limit.");
    uint32_t width = rows.width, height = rows.height;
    if (longEdge && longEdge < std::max(width, height)) {
        const double scale = double(longEdge) / std::max(width, height);
        width = std::max(1u, uint32_t(std::round(width * scale)));
        height = std::max(1u, uint32_t(std::round(height * scale)));
    }
    uint64_t budget = libraryBudget;
    auto account = [&](uint64_t bytes) {
        if (bytes > limits.max_working_bytes - budget || bytes > std::numeric_limits<size_t>::max())
            throw Failure("There is not enough memory to decode this TIFF at the requested size.");
        budget += bytes;
    };
    account(16u << 20); // Directory/container overhead and bounded colour-transform workspace.
    account(rows.layout.encoding.icc.size() * 8ull);
    account(rows.cacheBytes()); account(uint64_t(rows.width) * 128);
    const uint64_t outputSize = uint64_t(width) * height * 4 * sizeof(float);
    account(outputSize);
    const size_t outputBytes = size_t(outputSize);
    SceneConverter converter(rows.layout, options & FFC_DECODE_LINEAR_SAMPLES);
    out.rgba = static_cast<float *>(std::malloc(outputBytes));
    if (!out.rgba) throw std::bad_alloc();
    out.content_headroom = 1;
    const bool swap = rows.orientation >= 5;
    out.width = swap ? height : width; out.height = swap ? width : height;
    sourceWidth = swap ? rows.height : rows.width; sourceHeight = swap ? rows.width : rows.height;
    out.capture.stored_width = rows.width; out.capture.stored_height = rows.height;
    std::vector<float> input, upper(size_t(rows.width) * 4), lower(upper.size());
    uint32_t upperY = UINT32_MAX, lowerY = UINT32_MAX;
    auto convert = [&](uint32_t y, std::vector<float> &result) {
        rows.row(y, input); errors.check(); converter.row(input.data(), rows.width, result.data());
    };
    for (uint32_t y = 0; y < height; ++y) {
        const double sy = std::max(0.0, (y + 0.5) * rows.height / height - 0.5);
        const uint32_t y0 = uint32_t(sy), y1 = std::min(y0 + 1, rows.height - 1);
        const float fy = float(sy - y0);
        if (y0 == lowerY) { upper.swap(lower); std::swap(upperY, lowerY); }
        if (y0 != upperY) { convert(y0, upper); upperY = y0; }
        if (fy != 0 && y1 != lowerY) { convert(y1, lower); lowerY = y1; }
        const auto &bottom = fy == 0 ? upper : lower;
        for (uint32_t x = 0; x < width; ++x) {
            const double sx = std::max(0.0, (x + 0.5) * rows.width / width - 0.5);
            const uint32_t x0 = uint32_t(sx), x1 = std::min(x0 + 1, rows.width - 1);
            const float fx = float(sx - x0);
            uint32_t dx = x, dy = y;
            switch (rows.orientation) {
            case 2: dx = width - 1 - x; break;
            case 3: dx = width - 1 - x; dy = height - 1 - y; break;
            case 4: dy = height - 1 - y; break;
            case 5: dx = y; dy = x; break;
            case 6: dx = height - 1 - y; dy = x; break;
            case 7: dx = height - 1 - y; dy = width - 1 - x; break;
            case 8: dx = y; dy = width - 1 - x; break;
            }
            float *pixel = out.rgba + (size_t(dy) * out.width + dx) * 4;
            for (int c = 0; c < 4; ++c) {
                const float a = upper[size_t(x0) * 4 + c] * (1 - fx) + upper[size_t(x1) * 4 + c] * fx;
                const float b = bottom[size_t(x0) * 4 + c] * (1 - fx) + bottom[size_t(x1) * 4 + c] * fx;
                pixel[c] = a * (1 - fy) + b * fy;
            }
        }
    }
    basicCapture(tiff.get(), out.capture); errors.check();
}
} // namespace
} // namespace ffc

extern "C" int32_t ffc_decode_tiff(const char *path, uint32_t options, uint32_t longEdge,
    const ffc_tiff_limits *limits, ffc_image *out, uint32_t *sourceWidth, uint32_t *sourceHeight,
    char *error, size_t errorSize) {
    if (out) *out = {};
    if (sourceWidth) *sourceWidth = 0;
    if (sourceHeight) *sourceHeight = 0;
    if (error && errorSize) error[0] = 0;
    auto fail = [&](const char *message) { if (error && errorSize) std::snprintf(error, errorSize, "%s", message); };
    try {
        if (!path || !out || !sourceWidth || !sourceHeight || !limits || !limits->max_file_bytes
            || !limits->max_pixels || !limits->max_working_bytes || (options & ~(FFC_DECODE_SCAN | FFC_DECODE_LINEAR_SAMPLES)))
            throw ffc::Failure("Invalid TIFF decode request.");
        ffc::importTIFF(path, options, longEdge, *limits, *out, *sourceWidth, *sourceHeight);
        return FFC_TIFF_OK;
    } catch (const ffc::UnsupportedTIFF &failure) {
        fail(failure.what()); return FFC_TIFF_UNSUPPORTED;
    } catch (const std::bad_alloc &) { fail("There is not enough memory to decode this TIFF."); }
    catch (const std::exception &failure) { fail(failure.what()); }
    catch (...) { fail("The TIFF could not be decoded."); }
    ffc_image_free(out);
    if (sourceWidth) *sourceWidth = 0;
    if (sourceHeight) *sourceHeight = 0;
    return FFC_TIFF_ERROR;
}
#endif
