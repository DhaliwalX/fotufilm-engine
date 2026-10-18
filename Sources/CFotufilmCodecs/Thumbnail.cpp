// Thumbnails as ImageIO draws them on the Mac: a camera RAW's embedded preview, a JPEG decoded at
// a reduced DCT scale, a HEIF's stored thumbnail, else the image decoded and reduced; Display P3
// codes, upright, no larger than asked.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <type_traits>

namespace ffc {
namespace {

const std::array<float, 8> displayP3{0.680f, 0.320f, 0.265f, 0.690f, 0.150f, 0.060f, 0.3127f, 0.3290f};

/// The size that fits `maxEdge`, never larger than the source.
void fitted(uint32_t width, uint32_t height, uint32_t maxEdge, uint32_t &ow, uint32_t &oh) {
    const double scale = std::min(1.0, double(maxEdge) / double(std::max(width, height)));
    ow = std::max<uint32_t>(1, uint32_t(std::lround(width * scale)));
    oh = std::max<uint32_t>(1, uint32_t(std::lround(height * scale)));
}

/// Each output pixel the mean of the source pixels under it.
template <typename T>
std::vector<T> reduced(const T *source, uint32_t width, uint32_t height, int channels, uint32_t ow, uint32_t oh) {
    std::vector<T> out(size_t(ow) * oh * channels);
    std::vector<uint32_t> columns(ow + 1);
    for (uint32_t x = 0; x <= ow; ++x) columns[x] = uint32_t(uint64_t(x) * width / ow);
    parallelRows(oh, [&](uint32_t begin, uint32_t end) {
        float sum[4];
        for (uint32_t y = begin; y < end; ++y) {
            const uint32_t top = uint32_t(uint64_t(y) * height / oh);
            const uint32_t bottom = std::max(top + 1, uint32_t(uint64_t(y + 1) * height / oh));
            for (uint32_t x = 0; x < ow; ++x) {
                const uint32_t left = columns[x], right = std::max(left + 1, columns[x + 1]);
                std::fill(sum, sum + 4, 0.0f);
                for (uint32_t v = top; v < bottom; ++v) {
                    const T *row = source + (size_t(v) * width + left) * channels;
                    for (uint32_t u = left; u < right; ++u, row += channels)
                        for (int c = 0; c < channels; ++c) sum[c] += float(row[c]);
                }
                const float count = float((bottom - top) * (right - left));
                T *pixel = &out[(size_t(y) * ow + x) * channels];
                for (int c = 0; c < channels; ++c)
                    pixel[c] = std::is_integral<T>::value ? T(sum[c] / count + 0.5f) : T(sum[c] / count);
            }
        }
    });
    return out;
}

/// Turns 8-bit RGBA upright by an Exif orientation.
std::vector<uint8_t> upright(std::vector<uint8_t> rgba, uint32_t &width, uint32_t &height, int orientation) {
    if (orientation <= 1 || orientation > 8) return rgba;
    const uint32_t w = width, h = height;
    const bool swaps = orientation >= 5;
    const uint32_t ow = swaps ? h : w, oh = swaps ? w : h;
    std::vector<uint8_t> out(rgba.size());
    const auto *in = reinterpret_cast<const uint32_t *>(rgba.data());
    auto *to = reinterpret_cast<uint32_t *>(out.data());
    for (uint32_t y = 0; y < oh; ++y)
        for (uint32_t x = 0; x < ow; ++x) {
            uint32_t u = x, v = y;
            switch (orientation) {
            case 2: u = w - 1 - x; break;
            case 3: u = w - 1 - x; v = h - 1 - y; break;
            case 4: v = h - 1 - y; break;
            case 5: u = y; v = x; break;
            case 6: u = y; v = h - 1 - x; break;
            case 7: u = w - 1 - y; v = h - 1 - x; break;
            case 8: u = w - 1 - y; v = x; break;
            }
            to[size_t(y) * ow + x] = in[size_t(v) * w + u];
        }
    width = ow;
    height = oh;
    return out;
}

/// An 8-bit grey or RGB raster: reduced while still small codes, then to Display P3, upright.
std::vector<uint8_t> fromCodes(Raster &raster, uint32_t maxEdge, uint32_t &width, uint32_t &height) {
    fitted(raster.width, raster.height, maxEdge, width, height);
    if (width != raster.width || height != raster.height) {
        raster.data = reduced(raster.data.data(), raster.width, raster.height, raster.channels, width, height);
        raster.width = width;
        raster.height = height;
    }
    return upright(displayP3Codes(raster), width, height, raster.orientation);
}

/// Associated linear Rec. 2020, upright: reduced in light, then Display P3 codes.
std::vector<uint8_t> fromScene(const float *rgba, uint32_t sw, uint32_t sh, uint32_t maxEdge, uint32_t &width,
                               uint32_t &height) {
    fitted(sw, sh, maxEdge, width, height);
    const std::vector<float> small = reduced(rgba, sw, sh, 4, width, height);
    const auto m = inverse([] {
        const auto c = toRec2020(displayP3);
        return Matrix{c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]};
    }());
    static const std::array<uint8_t, 4096> encode = [] {
        std::array<uint8_t, 4096> codes{};
        for (size_t i = 0; i < codes.size(); ++i) {
            const double v = double(i) / (codes.size() - 1);
            codes[i] = uint8_t(std::lround(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * std::pow(v, 1 / 2.4) - 0.055)));
        }
        return codes;
    }();
    std::vector<uint8_t> out(size_t(width) * height * 4, 255);
    for (size_t i = 0; i < size_t(width) * height; ++i) {
        const float *p = &small[i * 4];
        const float a = p[3] > 0 ? p[3] : 1;
        for (int c = 0; c < 3; ++c) {
            const double v = (m[c * 3] * p[0] + m[c * 3 + 1] * p[1] + m[c * 3 + 2] * p[2]) / a;
            out[i * 4 + c] = encode[size_t(std::clamp(v, 0.0, 1.0) * (encode.size() - 1) + 0.5)];
        }
    }
    return out;
}

bool codes(const Raster &raster) {
    return raster.samples == Samples::U8 && !raster.cmyk && (raster.channels == 1 || raster.channels == 3);
}

} // namespace
} // namespace ffc

using namespace ffc;

extern "C" int32_t ffc_thumbnail(const char *path, uint32_t max_edge, ffc_picture *out, char *error,
                                 size_t error_size) {
    if (!out) return 1;
    std::memset(out, 0, sizeof *out);
    try {
        if (!path) throw Failure("No file was named.");
        const uint32_t edge = std::max<uint32_t>(1, max_edge);
        std::vector<uint8_t> rgba;
        uint32_t width = 0, height = 0;
        Raster raster;
        ffc_capture capture{};
        std::unique_ptr<ffc_capture, void (*)(ffc_capture *)> keep(&capture, [](ffc_capture *c) {
            std::free(c->exif);
        });
        const Kind kind = sniff(path);
        bool decoded = false;
        switch (kind) {
        case Kind::RAW: decoded = rawPreview(path, edge, raster); break;
        case Kind::JPEG: {
            const std::vector<uint8_t> file = readFile(path);
            raster = decodeJPEGReduced(file.data(), file.size(), edge);
            decoded = true;
            break;
        }
        case Kind::HEIF: raster = decodeHEIFReduced(path, edge); decoded = true; break;
        case Kind::PNG: raster = decodePNG(path, capture); decoded = true; break;
        case Kind::TIFF: raster = decodeTIFF(path, capture); decoded = true; break;
        case Kind::EXR: raster = decodeEXR(path, capture); decoded = true; break;
        default: throw Failure(std::string("Could not read image: ") + path);
        }
        if (decoded && codes(raster)) {
            rgba = fromCodes(raster, edge, width, height);
        } else if (decoded) {
            std::vector<float> scene = sceneLinear(raster, false);
            uint32_t sw = raster.width, sh = raster.height;
            raster.data = {};
            orient(scene, sw, sh, raster.orientation);
            rgba = fromScene(scene.data(), sw, sh, edge, width, height);
        } else {
            // A RAW with no usable preview: demosaiced just large enough.
            ffc_image image{};
            std::unique_ptr<ffc_image, void (*)(ffc_image *)> release(&image, ffc_image_free);
            decodeRaw(path, FFC_DECODE_SCENE, edge, image);
            rgba = fromScene(image.rgba, image.width, image.height, edge, width, height);
        }
        out->rgba = static_cast<uint8_t *>(std::malloc(rgba.size()));
        if (!out->rgba) throw std::bad_alloc();
        std::memcpy(out->rgba, rgba.data(), rgba.size());
        out->width = width;
        out->height = height;
        return 0;
    } catch (const std::bad_alloc &) {
        if (error && error_size) copyString(error, error_size, "There is not enough memory to draw this thumbnail.");
    } catch (const std::exception &failure) {
        if (error && error_size) copyString(error, error_size, failure.what());
    } catch (...) {
        if (error && error_size) copyString(error, error_size, "The thumbnail could not be drawn.");
    }
    ffc_picture_free(out);
    return 1;
}

extern "C" void ffc_picture_free(ffc_picture *picture) {
    if (!picture) return;
    std::free(picture->rgba);
    std::memset(picture, 0, sizeof *picture);
}

#endif
