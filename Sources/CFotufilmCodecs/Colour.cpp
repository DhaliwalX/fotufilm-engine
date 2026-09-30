// Colour: every decoded raster to associated linear Rec. 2020 through lcms2 (ICC profiles) or
// exact matrices (linear light), turned upright; and the Display P3 profile exports carry.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__) || defined(FFC_PORTABLE_CODECS)
#include "Codecs.hpp"

#include <lcms2.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>

namespace ffc {
namespace {

const std::array<float, 8> rec2020{0.708f, 0.292f, 0.170f, 0.797f, 0.131f, 0.046f,
                                   0.3127f, 0.3290f};
const std::array<float, 8> rec709{0.64f, 0.33f, 0.30f, 0.60f, 0.15f, 0.06f, 0.3127f, 0.3290f};
const std::array<float, 8> displayP3{0.680f, 0.320f, 0.265f, 0.690f, 0.150f, 0.060f,
                                     0.3127f, 0.3290f};

struct Profile {
    cmsHPROFILE handle;
    explicit Profile(cmsHPROFILE h) : handle(h) {}
    ~Profile() {
        if (handle) cmsCloseProfile(handle);
    }
    Profile(const Profile &) = delete;
    Profile &operator=(const Profile &) = delete;
};

cmsHPROFILE rgbProfile(const std::array<float, 8> &p, cmsToneCurve *curve) {
    cmsCIExyY white{p[6], p[7], 1};
    cmsCIExyYTRIPLE primaries{{p[0], p[1], 1}, {p[2], p[3], 1}, {p[4], p[5], 1}};
    cmsToneCurve *curves[3] = {curve, curve, curve};
    return cmsCreateRGBProfile(&white, &primaries, curves);
}

cmsToneCurve *srgbCurve() {
    const double parameters[5] = {2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045};
    return cmsBuildParametricToneCurve(nullptr, 4, parameters);
}

/// The profile a raster's samples are read through, matched to its channel count.
cmsHPROFILE inputProfile(const Raster &raster) {
    bool grey = raster.channels <= 2;
    if (raster.encoding.kind == Encoding::Profile && !raster.encoding.icc.empty()) {
        cmsHPROFILE embedded = cmsOpenProfileFromMem(raster.encoding.icc.data(),
                                                     cmsUInt32Number(raster.encoding.icc.size()));
        if (embedded) {
            auto space = cmsGetColorSpace(embedded);
            if ((grey && space == cmsSigGrayData) || (!grey && space == cmsSigRgbData))
                return embedded;
            cmsCloseProfile(embedded);
        }
    }
    // A stated gamut without a power reads through the sRGB curve (an nclx box's usual transfer).
    cmsToneCurve *curve = raster.encoding.kind == Encoding::Power && raster.encoding.gamma > 0
        ? cmsBuildGamma(nullptr, raster.encoding.gamma) : srgbCurve();
    cmsHPROFILE profile;
    if (grey) {
        cmsCIExyY white{raster.encoding.chromaticities[6], raster.encoding.chromaticities[7], 1};
        profile = cmsCreateGrayProfile(&white, curve);
    } else {
        profile = rgbProfile(raster.encoding.kind == Encoding::Power
                                 ? raster.encoding.chromaticities : rec709, curve);
    }
    cmsFreeToneCurve(curve);
    return profile;
}

cmsUInt32Number lcmsFormat(const Raster &raster) {
    bool grey = raster.channels <= 2, alpha = raster.channels == 2 || raster.channels == 4;
    cmsUInt32Number format = grey ? (COLORSPACE_SH(PT_GRAY) | CHANNELS_SH(1))
                                  : (COLORSPACE_SH(PT_RGB) | CHANNELS_SH(3));
    if (alpha) format |= EXTRA_SH(1);
    switch (raster.samples) {
    case Samples::U8: return format | BYTES_SH(1);
    case Samples::U16: return format | BYTES_SH(2);
    case Samples::F32: return format | BYTES_SH(4) | FLOAT_SH(1);
    }
    return format;
}

size_t sampleBytes(Samples samples) {
    return samples == Samples::U8 ? 1 : samples == Samples::U16 ? 2 : 4;
}

float sample(const Raster &raster, size_t index) {
    switch (raster.samples) {
    case Samples::U8: return raster.data[index] / 255.0f;
    case Samples::U16: {
        uint16_t v;
        std::memcpy(&v, raster.data.data() + index * 2, 2);
        return v / 65535.0f;
    }
    case Samples::F32: {
        float v;
        std::memcpy(&v, raster.data.data() + index * 4, 4);
        return v;
    }
    }
    return 0;
}

} // namespace

Matrix multiply(const Matrix &a, const Matrix &b) {
    Matrix m{};
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            for (int k = 0; k < 3; ++k) m[r * 3 + c] += a[r * 3 + k] * b[k * 3 + c];
    return m;
}

Matrix inverse(const Matrix &m) {
    double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7],
           i = m[8];
    double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (std::fabs(det) < 1e-12) throw Failure("singular colour matrix");
    return {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
}

/// Linear RGB to XYZ for these primaries and white (Y of white = 1).
Matrix rgbToXYZ(const std::array<float, 8> &p) {
    auto xyz = [](double x, double y) { return std::array<double, 3>{x / y, 1, (1 - x - y) / y}; };
    auto r = xyz(p[0], p[1]), g = xyz(p[2], p[3]), b = xyz(p[4], p[5]), w = xyz(p[6], p[7]);
    Matrix primaries{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
    Matrix inv = inverse(primaries);
    double s[3];
    for (int k = 0; k < 3; ++k) s[k] = inv[k * 3] * w[0] + inv[k * 3 + 1] * w[1] + inv[k * 3 + 2] * w[2];
    for (int row = 0; row < 3; ++row)
        for (int k = 0; k < 3; ++k) primaries[row * 3 + k] *= s[k];
    return primaries;
}

/// Bradford adaptation between two whites given as xy.
Matrix bradford(double sx, double sy, double dx, double dy) {
    const Matrix m{0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    auto cone = [&](double x, double y) {
        double X = x / y, Z = (1 - x - y) / y;
        return std::array<double, 3>{m[0] * X + m[1] + m[2] * Z, m[3] * X + m[4] + m[5] * Z,
                                     m[6] * X + m[7] + m[8] * Z};
    };
    auto s = cone(sx, sy), d = cone(dx, dy);
    Matrix scale{d[0] / s[0], 0, 0, 0, d[1] / s[1], 0, 0, 0, d[2] / s[2]};
    return multiply(inverse(m), multiply(scale, m));
}

Matrix xyzToRec2020() { return inverse(rgbToXYZ(rec2020)); }

std::vector<uint8_t> readFile(const std::string &path) {
    std::unique_ptr<FILE, int (*)(FILE *)> file(std::fopen(path.c_str(), "rb"), std::fclose);
    if (!file) throw Failure("Could not open " + path);
    std::vector<uint8_t> bytes;
    uint8_t buffer[1 << 16];
    size_t n;
    while ((n = std::fread(buffer, 1, sizeof buffer, file.get())) > 0)
        bytes.insert(bytes.end(), buffer, buffer + n);
    return bytes;
}

void copyString(char *destination, size_t size, const std::string &value) {
    if (size == 0) return;
    size_t n = std::min(size - 1, value.size());
    std::memcpy(destination, value.data(), n);
    destination[n] = 0;
}

void parallelRows(uint32_t rows, const std::function<void(uint32_t, uint32_t)> &body) {
    unsigned workers = std::max(1u, std::min(std::thread::hardware_concurrency(), 32u));
    workers = std::min<unsigned>(workers, std::max<uint32_t>(1, rows / 16));
    if (workers <= 1) {
        body(0, rows);
        return;
    }
    std::vector<std::thread> threads;
    uint32_t step = (rows + workers - 1) / workers;
    try {
        for (uint32_t begin = 0; begin < rows; begin += step)
            threads.emplace_back(body, begin, std::min(rows, begin + step));
    } catch (...) {
        // A thread allocation failure must reach the C error boundary, not std::terminate
        // when the already-created joinable threads are destroyed during unwinding.
        for (auto &thread : threads) thread.join();
        throw;
    }
    for (auto &thread : threads) thread.join();
}

std::array<float, 9> toRec2020(const std::array<float, 8> &chromaticities) {
    Matrix toXYZ = rgbToXYZ(chromaticities);
    if (std::fabs(chromaticities[6] - 0.3127f) > 1e-4f || std::fabs(chromaticities[7] - 0.3290f) > 1e-4f)
        toXYZ = multiply(bradford(chromaticities[6], chromaticities[7], 0.3127, 0.3290), toXYZ);
    Matrix m = multiply(inverse(rgbToXYZ(rec2020)), toXYZ);
    std::array<float, 9> out;
    for (int k = 0; k < 9; ++k) out[k] = float(m[k]);
    return out;
}

std::vector<float> sceneLinear(const Raster &raster, bool linearSamples) {
    const uint32_t width = raster.width, height = raster.height;
    const int channels = raster.channels;
    const bool alpha = channels == 2 || channels == 4, grey = channels <= 2;
    std::vector<float> rgba(size_t(width) * height * 4, 1.0f);
    const size_t rowBytes = size_t(width) * channels * sampleBytes(raster.samples);

    // Linear light converts by matrix, exactly and without bounds; everything else through lcms2.
    bool matrix = linearSamples || raster.encoding.kind == Encoding::Linear
        || (raster.encoding.kind == Encoding::Unstated && raster.samples == Samples::F32);
    if (matrix) {
        auto m = toRec2020(linearSamples ? rec709 : raster.encoding.kind == Encoding::Linear
                                                        ? raster.encoding.chromaticities : rec709);
        parallelRows(height, [&](uint32_t begin, uint32_t end) {
            for (uint32_t y = begin; y < end; ++y) {
                for (uint32_t x = 0; x < width; ++x) {
                    size_t in = (size_t(y) * width + x) * channels;
                    float r = sample(raster, in), g = grey ? r : sample(raster, in + 1),
                          b = grey ? r : sample(raster, in + 2);
                    float *out = &rgba[(size_t(y) * width + x) * 4];
                    out[0] = m[0] * r + m[1] * g + m[2] * b;
                    out[1] = m[3] * r + m[4] * g + m[5] * b;
                    out[2] = m[6] * r + m[7] * g + m[8] * b;
                    if (alpha) out[3] = sample(raster, in + channels - 1);
                }
            }
        });
    } else {
        Profile source(inputProfile(raster));
        cmsToneCurve *linear = cmsBuildGamma(nullptr, 1.0);
        Profile target(rgbProfile(rec2020, linear));
        cmsFreeToneCurve(linear);
        if (!source.handle || !target.handle) throw Failure("The colour profile could not be read.");
        cmsHTRANSFORM transform = cmsCreateTransform(
            source.handle, lcmsFormat(raster), target.handle, TYPE_RGB_FLT, INTENT_PERCEPTUAL,
            cmsFLAGS_NOCACHE | cmsFLAGS_HIGHRESPRECALC);
        if (!transform) throw Failure("The colour profile could not be applied.");
        parallelRows(height, [&](uint32_t begin, uint32_t end) {
            std::vector<float> row(size_t(width) * 3);
            for (uint32_t y = begin; y < end; ++y) {
                cmsDoTransform(transform, raster.data.data() + y * rowBytes, row.data(), width);
                for (uint32_t x = 0; x < width; ++x) {
                    float *out = &rgba[(size_t(y) * width + x) * 4];
                    std::memcpy(out, &row[size_t(x) * 3], 3 * sizeof(float));
                    if (alpha)
                        out[3] = sample(raster, (size_t(y) * width + x) * channels + channels - 1);
                }
            }
        });
        cmsDeleteTransform(transform);
    }
    if (alpha && !raster.associated) {
        parallelRows(height, [&](uint32_t begin, uint32_t end) {
            for (size_t i = size_t(begin) * width; i < size_t(end) * width; ++i)
                for (int c = 0; c < 3; ++c) rgba[i * 4 + c] *= rgba[i * 4 + 3];
        });
    }
    return rgba;
}

void orient(std::vector<float> &rgba, uint32_t &width, uint32_t &height, int orientation) {
    if (orientation <= 1 || orientation > 8) return;
    const uint32_t w = width, h = height;
    const bool swaps = orientation >= 5;
    const uint32_t ow = swaps ? h : w, oh = swaps ? w : h;
    std::vector<float> out(rgba.size());
    parallelRows(oh, [&](uint32_t begin, uint32_t end) {
        for (uint32_t y = begin; y < end; ++y) {
            for (uint32_t x = 0; x < ow; ++x) {
                uint32_t c = 0, r = 0;
                switch (orientation) {
                case 2: c = w - 1 - x; r = y; break;
                case 3: c = w - 1 - x; r = h - 1 - y; break;
                case 4: c = x; r = h - 1 - y; break;
                case 5: c = y; r = x; break;
                case 6: c = y; r = h - 1 - x; break;
                case 7: c = w - 1 - y; r = h - 1 - x; break;
                case 8: c = w - 1 - y; r = x; break;
                }
                std::memcpy(&out[(size_t(y) * ow + x) * 4], &rgba[(size_t(r) * w + c) * 4],
                            4 * sizeof(float));
            }
        }
    });
    rgba.swap(out);
    width = ow;
    height = oh;
}

const std::vector<uint8_t> &displayP3Profile() {
    static const std::vector<uint8_t> bytes = [] {
        cmsToneCurve *curve = srgbCurve();
        cmsHPROFILE profile = rgbProfile(displayP3, curve);
        cmsFreeToneCurve(curve);
        cmsMLU *description = cmsMLUalloc(nullptr, 1);
        cmsMLUsetASCII(description, "en", "US", "Display P3");
        cmsWriteTag(profile, cmsSigProfileDescriptionTag, description);
        cmsMLUfree(description);
        cmsMLU *copyright = cmsMLUalloc(nullptr, 1);
        cmsMLUsetASCII(copyright, "en", "US", "No copyright, use freely");
        cmsWriteTag(profile, cmsSigCopyrightTag, copyright);
        cmsMLUfree(copyright);
        cmsUInt32Number size = 0;
        cmsSaveProfileToMem(profile, nullptr, &size);
        std::vector<uint8_t> icc(size);
        cmsSaveProfileToMem(profile, icc.data(), &size);
        cmsCloseProfile(profile);
        return icc;
    }();
    return bytes;
}

} // namespace ffc

#endif
