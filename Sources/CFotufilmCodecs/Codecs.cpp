// The C interface: which codec a file needs, and the decoded or encoded result.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#if __has_include(<libraw/libraw.h>)
#include <libraw/libraw.h>
#else
#include <libraw.h>
#endif

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>

namespace ffc {
namespace {

enum class Kind { Unknown, JPEG, PNG, TIFF, EXR, HEIF, RAW };

std::string extension(const std::string &path) {
    size_t dot = path.find_last_of('.'), slash = path.find_last_of("/\\");
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return {};
    std::string ext = path.substr(dot + 1);
    for (auto &c : ext) c = char(std::tolower(static_cast<unsigned char>(c)));
    return ext;
}

bool rawExtension(const std::string &ext) {
    static const char *const names[] = {
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
        "rwl", "pef", "srw", "x3f", "3fr", "fff", "iiq", "erf", "mef", "mos", "kdc", "dcr",
        "mrw", "gpr", "raw",
    };
    return std::any_of(std::begin(names), std::end(names), [&](const char *n) { return ext == n; });
}

/// Whether a TIFF's first directory, if it lies in `head`, carries a DNGVersion.
bool hasDNGVersion(const std::vector<uint8_t> &head) {
    if (head.size() < 8) return false;
    bool little = head[0] == 'I';
    auto u16 = [&](size_t at) -> uint32_t {
        return little ? head[at] | head[at + 1] << 8 : head[at] << 8 | head[at + 1];
    };
    auto u32 = [&](size_t at) -> uint32_t {
        return little ? u16(at) | u16(at + 2) << 16 : u16(at) << 16 | u16(at + 2);
    };
    uint32_t offset = u32(4);
    if (offset + 2 > head.size()) return false;
    uint32_t count = u16(offset);
    for (uint32_t i = 0; i < count && offset + 2 + (i + 1) * 12 <= head.size(); ++i)
        if (u16(offset + 2 + i * 12) == 0xC612) return true;
    return false;
}

Kind sniff(const std::string &path) {
    std::unique_ptr<FILE, int (*)(FILE *)> file(std::fopen(path.c_str(), "rb"), std::fclose);
    if (!file) throw Failure("Could not open " + path);
    std::vector<uint8_t> head(1 << 20);
    head.resize(std::fread(head.data(), 1, head.size(), file.get()));
    auto starts = [&](std::initializer_list<uint8_t> magic, size_t at = 0) {
        if (head.size() < at + magic.size()) return false;
        return std::equal(magic.begin(), magic.end(), head.begin() + at);
    };
    if (starts({0xFF, 0xD8, 0xFF})) return Kind::JPEG;
    if (starts({0x89, 'P', 'N', 'G'})) return Kind::PNG;
    if (starts({0x76, 0x2F, 0x31, 0x01})) return Kind::EXR;
    if (starts({'f', 't', 'y', 'p'}, 4) && head.size() >= 12) {
        std::string brand(head.begin() + 8, head.begin() + 12);
        if (brand == "crx ") return Kind::RAW;
        return Kind::HEIF;
    }
    if (starts({'I', 'I', 42, 0}) || starts({'M', 'M', 0, 42}))
        return rawExtension(extension(path)) || hasDNGVersion(head) ? Kind::RAW : Kind::TIFF;
    // Other RAW containers (ORF, RW2, RAF, CRW, X3F, ...) are LibRaw's to recognise.
    auto raw = std::make_unique<LibRaw>(0);
    if (raw->open_file(path.c_str()) == LIBRAW_SUCCESS) return Kind::RAW;
    return Kind::Unknown;
}

void fail(char *error, size_t size, const std::string &message) {
    if (error && size) copyString(error, size, message);
}

} // namespace
} // namespace ffc

using namespace ffc;

extern "C" int32_t ffc_decode(const char *path, uint32_t options, uint32_t raw_long_edge,
                              ffc_image *out, char *error, size_t error_size) {
    if (!out) return 1;
    std::memset(out, 0, sizeof *out);
    out->content_headroom = 1;
    try {
        if (!path) throw Failure("No file was named.");
        const Kind kind = sniff(path);
        if (kind == Kind::RAW) {
            decodeRaw(path, options, raw_long_edge, *out);
            return 0;
        }
        Raster raster;
        switch (kind) {
        case Kind::JPEG: raster = decodeJPEG(path, out->capture); break;
        case Kind::PNG: raster = decodePNG(path, out->capture); break;
        case Kind::TIFF: raster = decodeTIFF(path, out->capture); break;
        case Kind::EXR: raster = decodeEXR(path, out->capture); break;
        case Kind::HEIF: raster = decodeHEIF(path, out->capture); break;
        default: throw Failure(std::string("Could not read image: ") + path);
        }
        std::vector<float> rgba = sceneLinear(raster, options & FFC_DECODE_LINEAR_SAMPLES);
        raster.data = {};
        uint32_t width = raster.width, height = raster.height;
        orient(rgba, width, height, raster.orientation);
        out->rgba = static_cast<float *>(std::malloc(rgba.size() * sizeof(float)));
        if (!out->rgba) throw std::bad_alloc();
        std::memcpy(out->rgba, rgba.data(), rgba.size() * sizeof(float));
        out->width = width;
        out->height = height;
        return 0;
    } catch (const std::bad_alloc &) {
        fail(error, error_size, "There is not enough memory to open this image.");
    } catch (const std::exception &failure) {
        fail(error, error_size, failure.what());
    } catch (...) {
        fail(error, error_size, "The image could not be read.");
    }
    ffc_image_free(out);
    return 1;
}

extern "C" void ffc_image_free(ffc_image *image) {
    if (!image) return;
    std::free(image->rgba);
    std::free(image->capture.exif);
    image->rgba = nullptr;
    image->capture.exif = nullptr;
    image->capture.exif_length = 0;
}

extern "C" int32_t ffc_can_encode(const char *mime) {
    if (!mime) return 0;
    std::string type(mime);
    if (type == "image/png" || type == "image/jpeg" || type == "image/tiff") return 1;
    if (type == "image/heic") return heifEncodes();
    return 0;
}

extern "C" int32_t ffc_encode(const char *path, const char *mime, const void *rgba, int32_t bits,
                              uint32_t width, uint32_t height, float quality, const uint8_t *exif,
                              size_t exif_length, int32_t keep_location, char *error,
                              size_t error_size) {
    try {
        if (!path || !mime || !rgba || width == 0 || height == 0 || (bits != 8 && bits != 16))
            throw Failure("Nothing to write.");
        const std::string type(mime);
        std::vector<uint8_t> record;
        try {
            record = exportExif(exif, exif_length, keep_location != 0);
        } catch (const Failure &) {
        }
        // RGB without alpha, as the Mac writes (`noneSkipLast`); 8 bits for the lossy formats.
        const bool deep = bits == 16 && (type == "image/png" || type == "image/tiff");
        const size_t pixels = size_t(width) * height;
        std::vector<uint8_t> rgb(pixels * 3 * (deep ? 2 : 1));
        if (bits == 8) {
            const auto *in = static_cast<const uint8_t *>(rgba);
            for (size_t i = 0; i < pixels; ++i) std::memcpy(&rgb[i * 3], in + i * 4, 3);
        } else {
            const auto *in = static_cast<const uint16_t *>(rgba);
            if (deep) {
                auto *out = reinterpret_cast<uint16_t *>(rgb.data());
                for (size_t i = 0; i < pixels; ++i) std::memcpy(out + i * 3, in + i * 4, 6);
            } else {
                for (size_t i = 0; i < pixels; ++i)
                    for (int c = 0; c < 3; ++c)
                        rgb[i * 3 + c] = uint8_t((uint32_t(in[i * 4 + c]) * 255 + 32767) / 65535);
            }
        }
        const int written = deep ? 16 : 8;
        if (type == "image/png") encodePNG(path, rgb.data(), written, width, height, record);
        else if (type == "image/jpeg") encodeJPEG(path, rgb.data(), width, height, quality, record);
        else if (type == "image/tiff")
            encodeTIFF(path, rgb.data(), written, width, height, exifText(record.data(), record.size()));
        else if (type == "image/heic" && heifEncodes())
            encodeHEIF(path, rgb.data(), width, height, quality, record);
        else throw Failure("This host cannot write " + type + ".");
        return 0;
    } catch (const std::bad_alloc &) {
        fail(error, error_size, "There is not enough memory to write this image.");
    } catch (const std::exception &failure) {
        fail(error, error_size, failure.what());
    } catch (...) {
        fail(error, error_size, "The image could not be written.");
    }
    return 1;
}

#endif
