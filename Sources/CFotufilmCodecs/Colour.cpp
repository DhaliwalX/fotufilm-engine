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
#include <mutex>
#include <exception>
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
            if ((grey && space == cmsSigGrayData) || (raster.cmyk && space == cmsSigCmykData)
                || (!grey && !raster.cmyk && space == cmsSigRgbData))
                return embedded;
            cmsCloseProfile(embedded);
        }
    }
    if (raster.encoding.kind == Encoding::Profile)
        throw Failure("The embedded colour profile is invalid or does not match the image channels.");
    if (raster.cmyk) throw Failure("A CMYK image requires an embedded CMYK colour profile.");
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

size_t sampleBytes(Samples samples) {
    return samples == Samples::U8 ? 1 : samples == Samples::U16 ? 2 : 4;
}
float sample(const uint8_t *data, Samples samples, size_t index) {
    if (samples == Samples::U8) return data[index] / 255.0f;
    if (samples == Samples::U16) {
        uint16_t value; std::memcpy(&value, data + index * 2, 2); return value / 65535.0f;
    }
    float value; std::memcpy(&value, data + index * 4, 4); return value;
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
    std::exception_ptr failure;
    std::mutex failureMutex;
    uint32_t step = (rows + workers - 1) / workers;
    try {
        for (uint32_t begin = 0; begin < rows; begin += step)
            threads.emplace_back([&, begin] {
                try { body(begin, std::min(rows, begin + step)); }
                catch (...) {
                    std::lock_guard<std::mutex> lock(failureMutex);
                    if (!failure) failure = std::current_exception();
                }
            });
    } catch (...) {
        // A thread allocation failure must reach the C error boundary, not std::terminate
        // when the already-created joinable threads are destroyed during unwinding.
        for (auto &thread : threads) thread.join();
        throw;
    }
    for (auto &thread : threads) thread.join();
    if (failure) std::rethrow_exception(failure);
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

struct SceneConverter::Impl {
    int channels, colours;
    Samples samples;
    bool alpha, associated, cmyk, matrix;
    std::array<float, 9> coefficients{};
    cmsHTRANSFORM transform = nullptr;
    Impl(const Raster &raster, bool linearSamples)
        : channels(raster.channels), colours(raster.cmyk ? 4 : raster.channels <= 2 ? 1 : 3),
          samples(raster.samples), alpha(channels == colours + 1), associated(raster.associated), cmyk(raster.cmyk) {
        if (channels != colours && channels != colours + 1) throw Failure("Invalid image channel layout.");
        // Samples with no stated encoding are linear light where asked (a scanner's raw output),
        // and always when they are floating point.
        const bool unstated = raster.encoding.kind == Encoding::Unstated;
        matrix = !cmyk && (raster.encoding.kind == Encoding::Linear
            || (unstated && (linearSamples || samples == Samples::F32)));
        if (matrix) {
            coefficients = toRec2020(raster.encoding.kind == Encoding::Linear
                ? raster.encoding.chromaticities : rec709);
            return;
        }
        Profile source(inputProfile(raster));
        cmsToneCurve *linear = cmsBuildGamma(nullptr, 1.0);
        Profile target(rgbProfile(rec2020, linear));
        cmsFreeToneCurve(linear);
        if (!source.handle || !target.handle) throw Failure("The colour profile could not be read.");
        transform = cmsCreateTransform(source.handle, cmyk ? TYPE_CMYK_FLT : colours == 1 ? TYPE_GRAY_FLT : TYPE_RGB_FLT,
            target.handle, TYPE_RGB_FLT, INTENT_PERCEPTUAL, cmsFLAGS_NOCACHE | cmsFLAGS_NOOPTIMIZE);
        if (!transform) throw Failure("The colour profile could not be applied.");
    }
    ~Impl() { if (transform) cmsDeleteTransform(transform); }
};

SceneConverter::SceneConverter(const Raster &raster, bool linearSamples) : impl_(new Impl(raster, linearSamples)) {}
SceneConverter::~SceneConverter() = default;

void SceneConverter::row(const void *source, uint32_t count, float *rgba) const {
    const auto &p = *impl_;
    const auto *bytes = static_cast<const uint8_t *>(source);
    std::vector<float> straight(p.matrix ? 0 : size_t(count) * p.colours);
    std::vector<float> converted(p.matrix ? 0 : size_t(count) * 3);
    for (uint32_t x = 0; x < count; ++x) {
        const size_t at = size_t(x) * p.channels;
        float a = p.alpha ? sample(bytes, p.samples, at + p.colours) : 1;
        if (!std::isfinite(a) || a < 0 || a > 1) throw Failure("The image contains invalid alpha samples.");
        rgba[size_t(x) * 4 + 3] = a;
        float values[4]{};
        for (int c = 0; c < p.colours; ++c) {
            values[c] = sample(bytes, p.samples, at + c);
            if (!std::isfinite(values[c])) throw Failure("The image contains nonfinite colour samples.");
        }
        if (p.matrix) {
            const float r = values[0], g = p.colours == 1 ? r : values[1], b = p.colours == 1 ? r : values[2];
            const float weight = a == 0 ? 0 : p.associated ? 1 : a;
            for (int c = 0; c < 3; ++c)
                rgba[size_t(x) * 4 + c] = (p.coefficients[c * 3] * r + p.coefficients[c * 3 + 1] * g
                    + p.coefficients[c * 3 + 2] * b) * weight;
        } else {
            // Associated encoded values must be unassociated BEFORE the nonlinear profile transform.
            for (int c = 0; c < p.colours; ++c) {
                float value = p.associated ? a > 0 ? values[c] / a : 0 : values[c];
                straight[size_t(x) * p.colours + c] = value * (p.cmyk ? 100 : 1);
            }
        }
    }
    if (!p.matrix) {
        cmsDoTransform(p.transform, straight.data(), converted.data(), count);
        for (uint32_t x = 0; x < count; ++x)
            for (int c = 0; c < 3; ++c) rgba[size_t(x) * 4 + c] = converted[size_t(x) * 3 + c] * rgba[size_t(x) * 4 + 3];
    }
    for (size_t i = 0; i < size_t(count) * 4; ++i)
        if (!std::isfinite(rgba[i])) throw Failure("The image colour conversion produced nonfinite samples.");
}

std::vector<float> sceneLinear(const Raster &raster, bool linearSamples) {
    SceneConverter converter(raster, linearSamples);
    std::vector<float> rgba(size_t(raster.width) * raster.height * 4);
    const size_t rowBytes = size_t(raster.width) * raster.channels * sampleBytes(raster.samples);
    parallelRows(raster.height, [&](uint32_t begin, uint32_t end) {
        for (uint32_t y = begin; y < end; ++y)
            converter.row(raster.data.data() + y * rowBytes, raster.width, rgba.data() + size_t(y) * raster.width * 4);
    });
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
