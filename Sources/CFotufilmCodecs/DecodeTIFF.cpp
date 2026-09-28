// TIFF through libtiff: 8-, 16- and 32-bit float grey or RGB, strips or tiles, chunky or planar,
// with alpha; other layouts (palette, YCbCr, CMYK, odd depths) through libtiff's 8-bit reader.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <algorithm>
#include <cstring>

#include <tiffio.h>

namespace ffc {
namespace {

/// libtiff reading from memory, so the Exif record is read from the same bytes.
struct Memory {
    const std::vector<uint8_t> *bytes;
    toff_t position = 0;
};

tsize_t memoryRead(thandle_t handle, tdata_t buffer, tsize_t size) {
    auto *memory = static_cast<Memory *>(handle);
    toff_t available = memory->position < memory->bytes->size()
        ? memory->bytes->size() - memory->position : 0;
    tsize_t n = tsize_t(std::min<toff_t>(available, toff_t(size)));
    std::memcpy(buffer, memory->bytes->data() + memory->position, size_t(n));
    memory->position += toff_t(n);
    return n;
}
tsize_t memoryWrite(thandle_t, tdata_t, tsize_t) { return 0; }
toff_t memorySeek(thandle_t handle, toff_t offset, int whence) {
    auto *memory = static_cast<Memory *>(handle);
    toff_t base = whence == SEEK_CUR ? memory->position
        : whence == SEEK_END ? memory->bytes->size() : 0;
    memory->position = base + offset;
    return memory->position;
}
int memoryClose(thandle_t) { return 0; }
toff_t memorySize(thandle_t handle) { return static_cast<Memory *>(handle)->bytes->size(); }
int memoryMap(thandle_t, tdata_t *, toff_t *) { return 0; }
void memoryUnmap(thandle_t, tdata_t, toff_t) {}

struct Closer {
    TIFF *tiff;
    ~Closer() { if (tiff) TIFFClose(tiff); }
};

} // namespace

Raster decodeTIFF(const std::string &path, ffc_capture &capture) {
    std::vector<uint8_t> file = readFile(path);
    Memory memory{&file};
    TIFFSetWarningHandler(nullptr);
    TIFF *tiff = TIFFClientOpen(path.c_str(), "rm", &memory, memoryRead, memoryWrite, memorySeek,
                                memoryClose, memorySize, memoryMap, memoryUnmap);
    if (!tiff) throw Failure("The TIFF could not be read.");
    Closer closer{tiff};

    Raster raster;
    uint32_t width = 0, height = 0;
    uint16_t bits = 8, spp = 1, format = SAMPLEFORMAT_UINT, photometric = PHOTOMETRIC_RGB,
             planar = PLANARCONFIG_CONTIG, orientation = ORIENTATION_TOPLEFT;
    TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLESPERPIXEL, &spp);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLEFORMAT, &format);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_PLANARCONFIG, &planar);
    TIFFGetFieldDefaulted(tiff, TIFFTAG_ORIENTATION, &orientation);
    if (!TIFFGetField(tiff, TIFFTAG_PHOTOMETRIC, &photometric))
        photometric = spp >= 3 ? PHOTOMETRIC_RGB : PHOTOMETRIC_MINISBLACK;
    if (width == 0 || height == 0 || uint64_t(width) * height > 1'000'000'000ull)
        throw Failure("The TIFF has no usable size.");
    raster.width = width;
    raster.height = height;
    capture.stored_width = width;
    capture.stored_height = height;

    uint32_t iccLength = 0;
    void *icc = nullptr;
    if (TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &iccLength, &icc) && icc && iccLength > 0) {
        raster.encoding.kind = Encoding::Profile;
        auto *bytes = static_cast<const uint8_t *>(icc);
        raster.encoding.icc.assign(bytes, bytes + iccLength);
    }
    try {
        parseExif(file.data(), file.size(), capture);
        keepExif(file.data(), file.size(), capture);
    } catch (const Failure &) {
    }

    uint16_t extraCount = 0;
    uint16_t *extraTypes = nullptr;
    TIFFGetField(tiff, TIFFTAG_EXTRASAMPLES, &extraCount, &extraTypes);
    const bool grey = photometric == PHOTOMETRIC_MINISBLACK || photometric == PHOTOMETRIC_MINISWHITE;
    const int colour = grey ? 1 : 3;
    const bool direct = (grey || photometric == PHOTOMETRIC_RGB) && spp >= colour
        && (((bits == 8 || bits == 16) && format == SAMPLEFORMAT_UINT)
            || (bits == 32 && format == SAMPLEFORMAT_IEEEFP));

    if (!direct) {
        // libtiff's own reader: 8-bit RGBA, turned by libtiff for the flipped orientations.
        std::vector<uint32_t> pixels(size_t(width) * height);
        if (!TIFFReadRGBAImageOriented(tiff, width, height, pixels.data(), ORIENTATION_TOPLEFT, 0))
            throw Failure("This TIFF layout is not supported.");
        raster.channels = 4;
        raster.samples = Samples::U8;
        raster.data.resize(size_t(width) * height * 4);
        for (size_t i = 0; i < pixels.size(); ++i) {
            uint32_t p = pixels[i];
            raster.data[i * 4] = uint8_t(TIFFGetR(p));
            raster.data[i * 4 + 1] = uint8_t(TIFFGetG(p));
            raster.data[i * 4 + 2] = uint8_t(TIFFGetB(p));
            raster.data[i * 4 + 3] = uint8_t(TIFFGetA(p));
        }
        raster.associated = true;
        return raster;
    }

    const bool alpha = spp > colour && extraCount > 0
        && (extraTypes[0] == EXTRASAMPLE_ASSOCALPHA || extraTypes[0] == EXTRASAMPLE_UNASSALPHA);
    raster.associated = alpha && extraTypes[0] == EXTRASAMPLE_ASSOCALPHA;
    raster.channels = colour + (alpha ? 1 : 0);
    raster.samples = bits == 8 ? Samples::U8 : bits == 16 ? Samples::U16 : Samples::F32;
    raster.orientation = orientation;
    const size_t bytes = bits / 8;
    raster.data.resize(size_t(width) * height * raster.channels * bytes);

    // Copies one decoded run of `count` pixels (starting at pixel x of row y) into the raster.
    auto place = [&](const uint8_t *source, uint32_t x, uint32_t y, uint32_t count, int plane) {
        if (y >= height) return;
        count = std::min(count, width - std::min(width, x));
        for (uint32_t i = 0; i < count; ++i) {
            uint8_t *out = raster.data.data() + ((size_t(y) * width + x + i) * raster.channels) * bytes;
            if (planar == PLANARCONFIG_CONTIG) {
                std::memcpy(out, source + size_t(i) * spp * bytes, raster.channels * bytes);
            } else if (plane < raster.channels) {
                std::memcpy(out + plane * bytes, source + size_t(i) * bytes, bytes);
            }
        }
    };
    const int planes = planar == PLANARCONFIG_CONTIG ? 1 : raster.channels;
    if (TIFFIsTiled(tiff)) {
        uint32_t tileWidth = 0, tileHeight = 0;
        TIFFGetField(tiff, TIFFTAG_TILEWIDTH, &tileWidth);
        TIFFGetField(tiff, TIFFTAG_TILELENGTH, &tileHeight);
        std::vector<uint8_t> tile(TIFFTileSize(tiff));
        const size_t tileRow = size_t(TIFFTileRowSize(tiff));
        for (int plane = 0; plane < planes; ++plane)
            for (uint32_t ty = 0; ty < height; ty += tileHeight)
                for (uint32_t tx = 0; tx < width; tx += tileWidth) {
                    if (TIFFReadTile(tiff, tile.data(), tx, ty, 0, uint16_t(plane)) < 0)
                        throw Failure("The TIFF could not be read.");
                    for (uint32_t row = 0; row < tileHeight; ++row)
                        place(tile.data() + row * tileRow, tx, ty + row, tileWidth, plane);
                }
    } else {
        std::vector<uint8_t> line(TIFFScanlineSize(tiff));
        for (int plane = 0; plane < planes; ++plane)
            for (uint32_t y = 0; y < height; ++y) {
                if (TIFFReadScanline(tiff, line.data(), y, uint16_t(plane)) < 0)
                    throw Failure("The TIFF could not be read.");
                place(line.data(), 0, y, width, plane);
            }
    }
    if (photometric == PHOTOMETRIC_MINISWHITE) {
        const size_t pixels = size_t(width) * height;
        for (size_t i = 0; i < pixels; ++i) {
            uint8_t *p = raster.data.data() + i * raster.channels * bytes;
            if (raster.samples == Samples::U8) {
                p[0] = uint8_t(255 - p[0]);
            } else if (raster.samples == Samples::U16) {
                uint16_t v;
                std::memcpy(&v, p, 2);
                v = uint16_t(65535 - v);
                std::memcpy(p, &v, 2);
            } else {
                float v;
                std::memcpy(&v, p, 4);
                v = 1 - v;
                std::memcpy(p, &v, 4);
            }
        }
    }
    return raster;
}

} // namespace ffc

#endif
