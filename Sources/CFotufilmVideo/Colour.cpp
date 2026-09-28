// Built where FFmpeg's headers are (Linux); elsewhere the platform's own framework decodes.
#if __has_include(<libavformat/avformat.h>)
#include "Colour.hpp"

#include <cmath>

namespace fotufilm::video {
namespace {

struct Chromaticities {
    double r[2], g[2], b[2], w[2];
};

constexpr Chromaticities kRec709{{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, {0.3127, 0.3290}};
constexpr Chromaticities kSMPTEC{{0.63, 0.34}, {0.31, 0.595}, {0.155, 0.07}, {0.3127, 0.3290}};
constexpr Chromaticities kEBU{{0.64, 0.33}, {0.29, 0.60}, {0.15, 0.06}, {0.3127, 0.3290}};
constexpr Chromaticities kRec2020{{0.708, 0.292}, {0.170, 0.797}, {0.131, 0.046}, {0.3127, 0.3290}};
constexpr Chromaticities kDisplayP3{{0.680, 0.320}, {0.265, 0.690}, {0.150, 0.060}, {0.3127, 0.3290}};

using Matrix3 = std::array<double, 9>;

Matrix3 multiply(const Matrix3 &a, const Matrix3 &b) {
    Matrix3 m{};
    for (int row = 0; row < 3; ++row)
        for (int column = 0; column < 3; ++column)
            for (int k = 0; k < 3; ++k) m[row * 3 + column] += a[row * 3 + k] * b[k * 3 + column];
    return m;
}

Matrix3 inverse(const Matrix3 &m) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7],
                 i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    return {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
}

/// Linear RGB to XYZ for a set of primaries.
Matrix3 to_xyz(const Chromaticities &p) {
    auto column = [](const double xy[2]) {
        return std::array<double, 3>{xy[0] / xy[1], 1.0, (1 - xy[0] - xy[1]) / xy[1]};
    };
    const auto r = column(p.r), g = column(p.g), b = column(p.b), w = column(p.w);
    const Matrix3 primaries{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
    const Matrix3 inv = inverse(primaries);
    double scale[3];
    for (int row = 0; row < 3; ++row)
        scale[row] = inv[row * 3] * w[0] + inv[row * 3 + 1] * w[1] + inv[row * 3 + 2] * w[2];
    Matrix3 m = primaries;
    for (int row = 0; row < 3; ++row)
        for (int column = 0; column < 3; ++column) m[row * 3 + column] *= scale[column];
    return m;
}

const Chromaticities &chromaticities(int primaries) {
    switch (primaries) {
    case 5: case 22: return kEBU;             // BT.470 BG, EBU Tech 3213
    case 6: case 7: return kSMPTEC;           // SMPTE 170M, 240M
    case 9: return kRec2020;
    case 11: case 12: return kDisplayP3;      // DCI-P3 is taken at D65, as Display P3
    default: return kRec709;
    }
}

Matrix between(int primaries, const Chromaticities &target) {
    const Matrix3 m = multiply(inverse(to_xyz(target)), to_xyz(chromaticities(primaries)));
    Matrix out{};
    for (int i = 0; i < 9; ++i) out[i] = static_cast<float>(m[i]);
    return out;
}

float srgb_linear(float v) {
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}

float srgb_encode(float v) {
    return v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f;
}

}  // namespace

SourceColour SourceColour::resolve(int transfer, int primaries, int matrix, bool full_range,
                                   int width, int height) {
    // CoreVideo's defaults for untagged video: HD is BT.709, anything smaller BT.601 / SMPTE C.
    const bool hd = width >= 1280 || height >= 720;
    SourceColour colour;
    colour.transfer = transfer == 2 || transfer == 0 ? 1 : transfer;
    colour.primaries = primaries == 2 || primaries == 0 ? (hd ? 1 : 6) : primaries;
    colour.matrix = matrix == 2 || matrix == 0 ? (hd ? 1 : 6) : matrix;
    colour.full_range = full_range;
    return colour;
}

Matrix SourceColour::to_display_p3() const { return between(primaries, kDisplayP3); }

Matrix SourceColour::to_rec2020() const { return between(primaries, kRec2020); }

YCbCr YCbCr::of(int matrix) {
    switch (matrix) {
    case 4: return {0.30f, 0.11f};                 // FCC
    case 5: case 6: return {0.299f, 0.114f};       // BT.601
    case 7: return {0.212f, 0.087f};               // SMPTE 240M
    case 9: case 10: return {0.2627f, 0.0593f};    // BT.2020
    default: return {0.2126f, 0.0722f};            // BT.709
    }
}

float sdr_linear(int transfer, float signal) {
    const float magnitude = std::fabs(signal);
    float linear;
    switch (transfer) {
    case 8: linear = magnitude; break;                              // linear
    case 13: linear = srgb_linear(magnitude); break;                // sRGB
    case 4: linear = std::pow(magnitude, 2.2f); break;              // BT.470 M
    case 5: linear = std::pow(magnitude, 2.8f); break;              // BT.470 BG
    default:
        // BT.709, BT.601, BT.2020 and untagged: ColorSync's video gamma, slope-limited.
        linear = std::fmax(std::pow(magnitude, 1.961f), magnitude / 16.0f);
    }
    return signal < 0 ? -linear : linear;
}

ManagedTables::ManagedTables(int transfer) : decode_(kEntries), encode_(65536) {
    for (int i = 0; i < kEntries; ++i)
        decode_[i] = sdr_linear(transfer, kLow + static_cast<float>(i) / kScale);
    for (int i = 0; i <= 65535; ++i) {
        const float code = srgb_encode(static_cast<float>(i) / kEncodeLast) * 255.0f;
        encode_[i] = static_cast<uint8_t>(std::fmin(std::fmax(code + 0.5f, 0.0f), 255.0f));
    }
}

}  // namespace fotufilm::video
#endif
