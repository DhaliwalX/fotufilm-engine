// Scalar reference for host-frame decoding, resampling, and print encoding.
// Keep each operation in a separate pass so optimized fused implementations can be compared
// against it. Transfer functions use the public `toLinear` and `fromLinear` implementations;
// `testWorkingSpace` validates their constants separately.

#include "TranscodeParity.h"

#include "WorkingSpace.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <random>
#include <string>
#include <vector>

extern "C" int32_t fotufilm_halide_metal_decode_rows(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters);
extern "C" int32_t fotufilm_halide_metal_available(void);

namespace fotufilm_test {
namespace {

// --------------------------------------------------------------- the reference

bool referenceRepair(float *pixels, int count) {
    bool clean = true;
    for (int i = 0; i < count; ++i) {
        float *pixel = pixels + i * 4;
        for (int channel = 0; channel < 3; ++channel) {
            if (!std::isfinite(pixel[channel])) { pixel[channel] = 0; clean = false; }
        }
        if (!std::isfinite(pixel[3])) { pixel[3] = 1; clean = false; }
    }
    return clean;
}

void referenceUnpremultiply(float *pixels, int count) {
    for (int i = 0; i < count; ++i) {
        const float alpha = pixels[i * 4 + 3];
        if (alpha <= 0 || alpha == 1) continue;
        const float scale = 1.0f / alpha;
        for (int c = 0; c < 3; ++c) pixels[i * 4 + c] *= scale;
    }
}

void referencePremultiply(float *pixels, int count) {
    for (int i = 0; i < count; ++i) {
        const float alpha = pixels[i * 4 + 3];
        if (alpha == 1) continue;
        for (int c = 0; c < 3; ++c) pixels[i * 4 + c] *= alpha;
    }
}

void referenceMatrix(const float *m, float *pixel) {
    const float r = pixel[0], g = pixel[1], b = pixel[2];
    pixel[0] = m[0] * r + m[1] * g + m[2] * b;
    pixel[1] = m[3] * r + m[4] * g + m[5] * b;
    pixel[2] = m[6] * r + m[7] * g + m[8] * b;
}

bool referenceDecodeInPlace(fotufilm::Encoding encoding, const fotufilm::Transform &transform,
                            float *pixels, int count) {
    bool clean = true;
    for (int i = 0; i < count; ++i) {
        float *pixel = pixels + i * 4;
        for (int c = 0; c < 3; ++c) {
            if (!std::isfinite(pixel[c])) { pixel[c] = 0; clean = false; }
        }
        if (!std::isfinite(pixel[3])) { pixel[3] = 1; clean = false; }
        for (int c = 0; c < 3; ++c) {
            pixel[c] = fotufilm::toLinear(encoding, pixel[c]);
            if (!std::isfinite(pixel[c])) { pixel[c] = 0; clean = false; }
        }
        referenceMatrix(transform.toWorking, pixel);
        for (int c = 0; c < 3; ++c) {
            if (!std::isfinite(pixel[c])) { pixel[c] = 0; clean = false; }
        }
    }
    return clean;
}

void referenceEncodeInPlace(fotufilm::Encoding encoding, const fotufilm::Transform &transform,
                            float *pixels, int count) {
    for (int i = 0; i < count; ++i) {
        float *pixel = pixels + i * 4;
        referenceMatrix(transform.fromWorking, pixel);
        for (int c = 0; c < 3; ++c) pixel[c] = fotufilm::fromLinear(encoding, pixel[c]);
    }
}

void referenceDecodeRow(const float *in, float *out, int sourceWidth, int processWidth,
                        bool premultiplied, fotufilm::Encoding encoding,
                        const fotufilm::Transform &transform, bool watchRange,
                        float &peak, bool &repaired) {
    for (int x = 0; x < sourceWidth; ++x) {
        const float *pixel = in + static_cast<size_t>(x) * 4;
        for (int channel = 0; channel < 4; ++channel) {
            if (!std::isfinite(pixel[channel])) repaired = true;
        }
        if (watchRange) {
            for (int channel = 0; channel < 3; ++channel) {
                if (std::isfinite(pixel[channel])) peak = std::max(peak, pixel[channel]);
            }
        }
    }

    if (processWidth == sourceWidth) {
        std::memcpy(out, in, static_cast<size_t>(sourceWidth) * 4 * sizeof(float));
        if (!referenceRepair(out, sourceWidth)) repaired = true;
        if (premultiplied) referenceUnpremultiply(out, sourceWidth);
        if (!referenceDecodeInPlace(encoding, transform, out, sourceWidth)) repaired = true;
        return;
    }

    for (int x = 0; x < processWidth; ++x) {
        const float position =
            (static_cast<float>(x) + 0.5f) * sourceWidth / processWidth - 0.5f;
        const int left =
            std::max(0, std::min(sourceWidth - 1, static_cast<int>(std::floor(position))));
        const int right = std::min(left + 1, sourceWidth - 1);
        const float mix = std::max(0.0f, std::min(1.0f, position - left));
        float a[4], b[4];
        std::memcpy(a, in + left * 4, sizeof(a));
        std::memcpy(b, in + right * 4, sizeof(b));
        const bool aWasFinite = referenceRepair(a, 1);
        const bool bWasFinite = referenceRepair(b, 1);
        if (!aWasFinite || !bWasFinite) repaired = true;
        if (premultiplied) {
            referenceUnpremultiply(a, 1);
            referenceUnpremultiply(b, 1);
        }
        const bool aClean = referenceDecodeInPlace(encoding, transform, a, 1);
        const bool bClean = referenceDecodeInPlace(encoding, transform, b, 1);
        if (!aClean || !bClean) repaired = true;
        for (int channel = 0; channel < 4; ++channel) {
            out[x * 4 + channel] = a[channel] + (b[channel] - a[channel]) * mix;
            if (!std::isfinite(out[x * 4 + channel])) {
                out[x * 4 + channel] = channel == 3 ? 1.0f : 0.0f;
                repaired = true;
            }
        }
    }
}

void referenceEncodeRow(const float *processed, float *span, int count, bool premultiplied,
                        fotufilm::Encoding encoding, const fotufilm::Transform &transform) {
    std::memcpy(span, processed, static_cast<size_t>(count) * 4 * sizeof(float));
    referenceEncodeInPlace(encoding, transform, span, count);
    if (premultiplied) referencePremultiply(span, count);
}

// ------------------------------------------------- the encode as the kernel spells it

float coefficientEncode(const fotufilm::OutputTransform &curve, float value) {
    const float *c = curve.coefficients;
    if (curve.shape == 0) return value;
    if (curve.shape == 1) {
        const float magnitude = std::fabs(value);
        const float sign = value < 0 ? -1.0f : 1.0f;
        return sign * (magnitude <= c[4] ? magnitude * c[0]
                                         : c[1] * std::pow(magnitude, c[2]) + c[3]);
    }
    return value <= c[4] ? value * c[0] + c[3]
                         : c[1] * std::log(value + c[5]) + c[2];
}

void kernelEncodeRow(const float *processed, float *span, int count, bool premultiplied,
                     const fotufilm::OutputTransform &curve,
                     const fotufilm::Transform &transform) {
    const float *m = transform.fromWorking;
    for (int i = 0; i < count; ++i) {
        const float *in = processed + static_cast<size_t>(i) * 4;
        float *out = span + static_cast<size_t>(i) * 4;
        const float r = in[0], g = in[1], b = in[2], alpha = in[3];
        for (int row = 0; row < 3; ++row) {
            out[row] = coefficientEncode(
                curve, m[row * 3] * r + m[row * 3 + 1] * g + m[row * 3 + 2] * b);
        }
        out[3] = alpha;
        if (premultiplied && alpha != 1) {
            for (int channel = 0; channel < 3; ++channel) out[channel] *= alpha;
        }
    }
}

// ------------------------------------------------------------- what is measured

// The two combinations `FotufilmPlugin.cpp` renders through — `decodeRows` and `writeStripRows`.
// Keep these in step with it: they are a mirror, and a stale mirror appears as a fast-path bug.

void subjectDecodeRow(const float *in, float *out, int sourceWidth, int processWidth,
                      bool premultiplied, fotufilm::Encoding encoding,
                      const fotufilm::Transform &transform, bool watchRange,
                      float &peak, bool &repaired, std::vector<float> &scratch) {
    const bool resampling = processWidth != sourceWidth;
    if (resampling) scratch.resize(static_cast<size_t>(sourceWidth) * 4);
    float *decoded = resampling ? scratch.data() : out;

    const fotufilm::DecodeReport report = fotufilm::decodePixels(
        encoding, transform, in, decoded, sourceWidth, premultiplied, watchRange);
    if (!report.clean) repaired = true;
    // Do not merge this single-row peak with +0: `std::max` would convert -0 to +0 and hide the
    // initialization behavior under test.
    peak = report.peak;
    if (resampling && !fotufilm::resampleRow(decoded, sourceWidth, out, processWidth)) {
        repaired = true;
    }
}

void subjectEncodeRow(const float *processed, float *span, int count, bool premultiplied,
                      fotufilm::Encoding encoding, const fotufilm::Transform &transform) {
    fotufilm::encodePixels(encoding, transform, processed, span, count, premultiplied);
}

// ------------------------------------------------------------------- the pixels

void fillPictorial(std::vector<float> &pixels, int count, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> value(0.0f, 1.1f);
    pixels.assign(static_cast<size_t>(count) * 4, 0.0f);
    for (int i = 0; i < count; ++i) {
        for (int c = 0; c < 3; ++c) pixels[i * 4 + c] = value(rng);
        pixels[i * 4 + 3] = 1.0f;
    }
}

void fillAdversarial(std::vector<float> &pixels, int count, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> ordinary(-0.2f, 1.4f);
    const float specials[] = {
        0.0f, -0.0f, 1.0f,
        0.04045f, 0.0031308f,            // sRGB's break, decoding and encoding
        0.0078125f, 0.155251141552511f,  // ACEScct's
        0.00262409f, 0.02740668f,        // DaVinci Intermediate's
        1e-30f, -1e-30f, 1e20f, -1e20f, 65504.0f,
        // Finite, but near enough the top of the type that summing three of them through a
        // matrix row leaves it — the one way an already-repaired pixel goes non-finite again
        // with no transfer function involved.
        3e38f, -3e38f,
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::denorm_min(),
    };
    const int specialCount = static_cast<int>(sizeof(specials) / sizeof(*specials));

    pixels.assign(static_cast<size_t>(count) * 4, 0.0f);
    for (int i = 0; i < count; ++i) {
        for (int c = 0; c < 4; ++c) {
            pixels[i * 4 + c] = rng() % 100 < 12 ? specials[rng() % specialCount]
                                                 : ordinary(rng);
        }
        const uint32_t alpha = rng() % 100;
        if (alpha < 25) pixels[i * 4 + 3] = 1.0f;
        else if (alpha < 35) pixels[i * 4 + 3] = 0.0f;
        else if (alpha < 45) pixels[i * 4 + 3] = 1e-38f;
        else if (alpha < 50) pixels[i * 4 + 3] = specials[rng() % specialCount];
        else pixels[i * 4 + 3] = std::uniform_real_distribution<float>(0.0f, 1.0f)(rng);
    }

}

void fillMatrixOverflow(std::vector<float> &pixels, int count) {
    const float huge = 3.3e38f;
    pixels.assign(static_cast<size_t>(count) * 4, 0.0f);
    for (int i = 0; i < count; ++i) {
        float *pixel = pixels.data() + static_cast<size_t>(i) * 4;
        pixel[0] = (i & 1) ? huge : -huge;
        pixel[1] = (i & 2) ? huge : -huge;
        pixel[2] = (i & 4) ? huge : -huge;
        pixel[3] = 1.0f;
    }
}

void fillLightless(std::vector<float> &pixels, int count, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> negative(-4.0f, -0.001f);
    const float specials[] = {
        -0.0f,
        -std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
    };
    pixels.assign(static_cast<size_t>(count) * 4, 0.0f);
    for (int i = 0; i < count; ++i) {
        for (int c = 0; c < 3; ++c) {
            pixels[i * 4 + c] = rng() % 100 < 30 ? specials[rng() % 4] : negative(rng);
        }
        pixels[i * 4 + 3] = rng() % 2 ? 1.0f : std::uniform_real_distribution<float>(
                                                   0.0f, 1.0f)(rng);
    }
}

// ------------------------------------------------------------------ comparison

bool identical(const std::vector<float> &a, const std::vector<float> &b, const char *what,
               const char *where, int &reported) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        uint32_t left, right;
        std::memcpy(&left, &a[i], sizeof(left));
        std::memcpy(&right, &b[i], sizeof(right));
        if (left == right) continue;
        if (reported++ < 4) {
            std::printf("       %s, %s: float %zu is %.9g (%08x), was %.9g (%08x)\n",
                        where, what, i, b[i], right, a[i], left);
        }
        return false;
    }
    return true;
}

bool sameFloat(float a, float b) {
    uint32_t left, right;
    std::memcpy(&left, &a, sizeof(left));
    std::memcpy(&right, &b, sizeof(right));
    return left == right;
}

const char *kEncodingNames[] = {"Rec.709", "sRGB",  "DaVinci Intermediate",
                                "ACEScct", "ACEScg", "Linear Rec.709",
                                "Linear Display P3", "Linear Rec.2020"};

double seconds(std::chrono::steady_clock::time_point from,
               std::chrono::steady_clock::time_point to) {
    return std::chrono::duration<double>(to - from).count();
}

void reportThroughput() {
    const int width = 3840, height = 256, repeats = 20;
    std::printf("\ntranscode throughput, %d x %d rows, best of %d, one thread\n", width,
                height, repeats);
    std::printf("       %-20s %10s %10s %10s\n", "encoding", "decode", "encode",
                "anamorphic");

    std::vector<float> in;
    fillPictorial(in, width, 4242u);
    const int squareWidth = static_cast<int>(std::llround(width * 1.33));
    std::vector<float> out(static_cast<size_t>(width) * 4);
    std::vector<float> span(static_cast<size_t>(width) * 4);
    std::vector<float> wide(static_cast<size_t>(squareWidth) * 4);
    std::vector<float> scratch;

    for (int e = 0; e < static_cast<int>(fotufilm::Encoding::Count); ++e) {
        const auto encoding = static_cast<fotufilm::Encoding>(e);
        const fotufilm::Transform transform = fotufilm::transformFor(encoding);
        // The over-range scan runs exactly where the plugin runs it: on the display-referred
        // spaces, until one of them has warned.
        const bool watch = encoding == fotufilm::Encoding::Rec709Gamma24 ||
                           encoding == fotufilm::Encoding::SRGB;
        double decode = 1e30, encode = 1e30, anamorphic = 1e30;
        for (int r = 0; r < repeats; ++r) {
            float peak = 0;
            bool repaired = false;
            const auto t0 = std::chrono::steady_clock::now();
            for (int y = 0; y < height; ++y) {
                subjectDecodeRow(in.data(), out.data(), width, width, false, encoding,
                                 transform, watch, peak, repaired, scratch);
            }
            const auto t1 = std::chrono::steady_clock::now();
            for (int y = 0; y < height; ++y) {
                subjectEncodeRow(out.data(), span.data(), width, false, encoding, transform);
            }
            const auto t2 = std::chrono::steady_clock::now();
            for (int y = 0; y < height; ++y) {
                subjectDecodeRow(in.data(), wide.data(), width, squareWidth, false, encoding,
                                 transform, watch, peak, repaired, scratch);
            }
            const auto t3 = std::chrono::steady_clock::now();
            decode = std::min(decode, seconds(t0, t1));
            encode = std::min(encode, seconds(t1, t2));
            anamorphic = std::min(anamorphic, seconds(t2, t3));
        }
        std::printf("       %-20s %8.1fms %8.1fms %8.1fms\n", kEncodingNames[e],
                    decode * 1e3, encode * 1e3, anamorphic * 1e3);
    }
}

// ------------------------------------------------ the decode as the kernel runs it

void packInputTransform(const fotufilm::Transform &transform,
                        const fotufilm::InputTransform &curve, bool premultiplied,
                        float parameters[17]) {
    std::memcpy(parameters, transform.toWorking, 9 * sizeof(float));
    parameters[9] = static_cast<float>(curve.shape);
    std::memcpy(parameters + 10, curve.coefficients, 6 * sizeof(float));
    parameters[16] = premultiplied ? 1.0f : 0.0f;
}

struct DecodeGap {
    double absolute = 0;
    double relative = 0;
    double host = 0, kernel = 0;
    const char *where = "";
    float sent[4] = {0, 0, 0, 0};
};

void testDeviceDecodeParity(void (*check)(bool, const char *)) {
    if (!fotufilm_halide_metal_available()) {
        std::printf("       no Metal device; the device decode is not measured here\n");
        return;
    }

    const int width = 331, height = 47;
    const int pixels = width * height;
    bool repairAgrees = true, peakAgrees = true, ran = true;
    bool alphaIsUntouched = true, branchesAgree = true;
    DecodeGap worstWorking, worstConditioned;
    long long excludedComponents = 0, comparedPixels = 0;
    int reported = 0;
    // Past this, a matrix row's three products may or may not overflow depending on whether they
    // were summed with a fused multiply-add. Twenty orders of magnitude past the largest value
    // any image format carries, so it excludes nothing a host could send.
    const float extremeMagnitude = 1e30f;

    for (int e = 0; e < static_cast<int>(fotufilm::Encoding::Count); ++e) {
        const auto encoding = static_cast<fotufilm::Encoding>(e);
        const fotufilm::Transform transform = fotufilm::transformFor(encoding);
        const fotufilm::InputTransform curve = fotufilm::inputTransformFor(encoding);

        for (int kind = 0; kind < 4; ++kind) {
            const char *kindName = kind == 0   ? "pictorial"
                                   : kind == 1 ? "adversarial"
                                   : kind == 2 ? "lightless"
                                               : "matrix overflow";
            std::vector<float> in;
            if (kind == 0) fillPictorial(in, pixels, 99u + e * 3);
            else if (kind == 1) fillAdversarial(in, pixels, 1234u + e * 7);
            else if (kind == 2) fillLightless(in, pixels, 555u + e * 11);
            else fillMatrixOverflow(in, pixels);

            for (int premultiplied = 0; premultiplied < 2; ++premultiplied) {
                char where[160];
                std::snprintf(where, sizeof(where), "%s, %s, %s", kEncodingNames[e], kindName,
                              premultiplied ? "premultiplied" : "straight");
                comparedPixels += 3 * pixels;

                // Which pixels the two sides are not being held to each other on, taken from the
                // host's own input before anything has touched it. Both reasons are properties of
                // the arithmetic rather than of this decode, and both are far outside anything an
                // image can carry — see `extremeMagnitude` and the note on the divide below.
                std::vector<char> excluded(static_cast<size_t>(pixels), 0);
                for (int i = 0; i < pixels; ++i) {
                    for (int c = 0; c < 3; ++c) {
                        if (std::fabs(in[i * 4 + c]) > extremeMagnitude) excluded[i] = 1;
                    }
                    // A premultiplied pixel whose alpha is subnormal. The host divides by it and
                    // reaches infinity, which it then repairs to black; the GPU flushes subnormals
                    // to zero, sees an alpha of nothing, and leaves the colour alone — so the two
                    // disagree about whether the pixel was ever divided. Both are defensible on a
                    // matte of 1e-45, which says the pixel is not there at all, and neither is
                    // something a compositor produces.
                    const float alpha = std::fabs(in[i * 4 + 3]);
                    if (premultiplied && alpha > 0 && alpha < std::numeric_limits<float>::min()) {
                        excluded[i] = 1;
                    }
                }

                // The largest term entering each pixel's matrix rows — the decode up to but not
                // including the matrix. It is the scale a disagreement about that pixel has to be
                // read against, because the matrix is a sum of three of these and its result may
                // be very much smaller than any of them. ACEScct sends 2.15 to 3.4e8, and three
                // numbers that size cancelling to -1900 turn a last-bit disagreement about one of
                // them into a whole unit of the answer. That is the conditioning of the transform
                // the host asked for, not something either side did wrong.
                std::vector<float> term(static_cast<size_t>(pixels), 0.0f);
                for (int i = 0; i < pixels; ++i) {
                    float pixel[4];
                    std::memcpy(pixel, in.data() + i * 4, sizeof(pixel));
                    referenceRepair(pixel, 1);
                    if (premultiplied) referenceUnpremultiply(pixel, 1);
                    for (int c = 0; c < 3; ++c) {
                        const float linear = fotufilm::toLinear(encoding, pixel[c]);
                        if (std::isfinite(linear)) term[i] = std::max(term[i], std::fabs(linear));
                    }
                }

                // The host's answer, row by row, exactly as `decodeRows` reaches it — including
                // the fold of the per-row reports, which is what the kernel's report replaces.
                std::vector<float> wanted(static_cast<size_t>(pixels) * 4, 7.0f);
                float wantedPeak = 0;
                bool wantedRepair = false;
                for (int row = 0; row < height; ++row) {
                    const size_t offset = static_cast<size_t>(row) * width * 4;
                    const fotufilm::DecodeReport report = fotufilm::decodePixels(
                        encoding, transform, in.data() + offset, wanted.data() + offset, width,
                        premultiplied != 0, true);
                    if (!report.clean) wantedRepair = true;
                    wantedPeak = std::max(wantedPeak, report.peak);
                }

                float parameters[17];
                packInputTransform(transform, curve, premultiplied != 0, parameters);
                std::vector<float> got(static_cast<size_t>(pixels) * 4, 7.0f);
                std::vector<float> report(static_cast<size_t>(height) * 2, -1.0f);
                if (fotufilm_halide_metal_decode_rows(0, in.data(), 0, got.data(), report.data(),
                                                     width, height, parameters) != 0) {
                    std::printf("       %s: the decode kernel refused the frame\n", where);
                    ran = false;
                    continue;
                }
                float gotPeak = 0;
                bool gotRepair = false;
                for (int row = 0; row < height; ++row) {
                    gotPeak = std::max(gotPeak, report[row * 2]);
                    if (report[row * 2 + 1] != 0) gotRepair = true;
                }

                if (wantedRepair != gotRepair) {
                    std::printf("       %s, device decode: repair reported as %d, was %d\n",
                                where, gotRepair, wantedRepair);
                    repairAgrees = false;
                }
                // A max over the host's own floats, with no arithmetic anywhere in it, so this is
                // the one number the GPU has no licence to move at all.
                if (!sameFloat(wantedPeak, gotPeak)) {
                    std::printf("       %s, device decode: peak is %.9g, was %.9g\n", where,
                                gotPeak, wantedPeak);
                    peakAgrees = false;
                }

                for (size_t i = 0; i < wanted.size(); ++i) {
                    const double host = wanted[i], kernel = got[i];
                    if (sameFloat(wanted[i], got[i])) continue;
                    // Alpha is repaired and copied, never decoded, so nothing may move it.
                    if ((i % 4) == 3) {
                        alphaIsUntouched = false;
                        if (reported++ < 4) {
                            std::printf("       %s, device decode: alpha %zu is %.9g, was %.9g\n",
                                        where, i, kernel, host);
                        }
                        continue;
                    }
                    // The pixels held out above, at the two ends of what a float can represent
                    // rather than anywhere a photograph lives. Counted, and reported below.
                    if (excluded[i / 4]) { ++excludedComponents; continue; }
                    if (!std::isfinite(host) || !std::isfinite(kernel)) {
                        // Below that line a repaired frame carries no non-finite value out, so
                        // either side holding one is the two disagreeing about a branch rather
                        // than about a curve — and no tolerance covers that.
                        branchesAgree = false;
                        if (reported++ < 4) {
                            std::printf("       %s, device decode: float %zu is %.9g, was %.9g\n",
                                        where, i, kernel, host);
                        }
                        continue;
                    }
                    const double gap = std::fabs(host - kernel);
                    const float *sent = in.data() + (i / 4) * 4;
                    // Against the terms the matrix summed, which is the only scale a cancelling
                    // dot product leaves meaning in — and, unlike the encode's, the decode's
                    // output has no upper end to hold it against: it is scene-linear light.
                    const double conditioned = gap / std::max(1.0f, term[i / 4]);
                    // Light a frame can actually be developed from: the pixel's largest term is
                    // within four stops of white.
                    if (term[i / 4] <= 16.0f && conditioned > worstWorking.relative) {
                        worstWorking = {gap, conditioned, host, kernel, kEncodingNames[e],
                                        {sent[0], sent[1], sent[2], sent[3]}};
                    }
                    if (conditioned > worstConditioned.relative) {
                        worstConditioned = {gap, conditioned, host, kernel, kEncodingNames[e],
                                            {sent[0], sent[1], sent[2], sent[3]}};
                    }
                }
            }
        }
    }

    check(ran, "the decode kernel runs every colour space over a frame no tile divides");
    check(repairAgrees, "the kernel repairs exactly the frames the host repairs");
    check(peakAgrees, "and reports the same over-range peak, to the bit");
    check(alphaIsUntouched, "and hands the matte back untouched, to the bit");
    check(branchesAgree,
          "and takes the same branch on every pixel a host could send: no finite for "
          "non-finite, and none the other way");
    // What is being measured here is a float exponential against a double one. The host computes
    // DaVinci Intermediate and ACEScct in double and the kernel in float, and a base-two curve
    // turns one ulp of its argument straight into that much relative error in its result — so a
    // part in a million is the floor, not a slack tolerance, and no rearrangement gets under it.
    std::printf("       over light a frame can be developed from the device decode is within "
                "%.3g of the terms it summed (worst: %s)\n", worstWorking.relative,
                worstWorking.where[0] ? worstWorking.where : "none");
    if (worstWorking.relative > 0) {
        std::printf("       on %.9g %.9g %.9g / %.9g: %.9g, was %.9g\n", worstWorking.sent[0],
                    worstWorking.sent[1], worstWorking.sent[2], worstWorking.sent[3],
                    worstWorking.kernel, worstWorking.host);
    }
    std::printf("       and over everything, including the pixels no host could send, within "
                "%.3g of the terms it summed (worst: %s)\n", worstConditioned.relative,
                worstConditioned.where[0] ? worstConditioned.where : "none");
    if (worstConditioned.relative > 0) {
        std::printf("       on %.9g %.9g %.9g / %.9g: %.9g, was %.9g\n", worstConditioned.sent[0],
                    worstConditioned.sent[1], worstConditioned.sent[2], worstConditioned.sent[3],
                    worstConditioned.kernel, worstConditioned.host);
    }
    std::printf("       %lld of %lld components were held out, above %.0g or behind a subnormal "
                "matte; those are counted, not compared\n",
                excludedComponents, comparedPixels, static_cast<double>(extremeMagnitude));
    check(worstWorking.relative < 2e-6,
          "the decoded light stays within a couple of parts in a million of the host's");
    check(worstConditioned.relative < 2e-5,
          "and stays within twenty even where the exponent runs off the end of the format");
}

}  // namespace

void testTranscodeParity(void (*check)(bool, const char *)) {
    std::printf("transcode parity\n");

    // Square pixels, then a pixel aspect that stretches the frame, then one that squeezes it —
    // the resample runs in both directions, and only the first path can memcpy.
    const int geometries[][2] = {{512, 512}, {512, 1024}, {512, 300}};

    bool decodeAgrees = true, encodeAgrees = true;
    bool repairAgrees = true, peakAgrees = true, inPlaceAgrees = true;
    int reported = 0;

    // A 16-bit delivery's least significant bit. The coefficient form of a logarithmic curve
    // cannot be the host's float for float — the host computes DaVinci Intermediate and ACEScct
    // in double and these coefficients are float — so what is asked of it is that the gap stay
    // far below anything a delivered frame can carry.
    //
    // Held two ways, because one number cannot describe both halves of what arrives here. Inside
    // the range a delivery lives in, what matters is the absolute gap against that LSB. Outside
    // it — the adversarial pixels reach 3e38, and an alpha of the same size multiplies an encoded
    // value back up to one — an absolute bound is meaningless: a single ulp there is 2e31, and no
    // arithmetic of any kind could pass. So those are held relatively instead, which is the same
    // claim in the only units that survive the magnitude.
    const double lsb16 = 1.0 / 65535.0;
    double worstDeliveryGap = 0, worstRelativeGap = 0;
    bool exactShapesAreExact = true;
    const char *worstCoefficientWhere = "";
    double worstHost = 0, worstKernel = 0;
    float worstDelivered[4] = {0, 0, 0, 0};

    for (int e = 0; e < static_cast<int>(fotufilm::Encoding::Count); ++e) {
        const auto encoding = static_cast<fotufilm::Encoding>(e);
        const fotufilm::Transform transform = fotufilm::transformFor(encoding);
        const fotufilm::OutputTransform curve = fotufilm::outputTransformFor(encoding);

        for (int kind = 0; kind < 4; ++kind) {
            const char *kindName = kind == 0   ? "pictorial"
                                   : kind == 1 ? "adversarial"
                                   : kind == 2 ? "lightless"
                                               : "matrix overflow";
            for (const auto &geometry : geometries) {
                const int sourceWidth = geometry[0], processWidth = geometry[1];
                std::vector<float> in;
                if (kind == 0) fillPictorial(in, sourceWidth, 99u + e * 3);
                else if (kind == 1) fillAdversarial(in, sourceWidth, 1234u + e * 7);
                else if (kind == 2) fillLightless(in, sourceWidth, 555u + e * 11);
                else fillMatrixOverflow(in, sourceWidth);

                for (int premultiplied = 0; premultiplied < 2; ++premultiplied) {
                    for (int watch = 0; watch < 2; ++watch) {
                        char where[160];
                        std::snprintf(where, sizeof(where), "%s, %s, %d to %d, %s%s",
                                      kEncodingNames[e], kindName, sourceWidth, processWidth,
                                      premultiplied ? "premultiplied" : "straight",
                                      watch ? ", watching range" : "");

                        // Prefilled with a value neither side would ever write, so a row left
                        // short shows up as a difference rather than as agreement about zero.
                        std::vector<float> wanted(static_cast<size_t>(processWidth) * 4, 7.0f);
                        std::vector<float> got(static_cast<size_t>(processWidth) * 4, 7.0f);
                        float wantedPeak = 0, gotPeak = 0;
                        bool wantedRepair = false, gotRepair = false;
                        std::vector<float> scratch;

                        referenceDecodeRow(in.data(), wanted.data(), sourceWidth, processWidth,
                                           premultiplied, encoding, transform, watch,
                                           wantedPeak, wantedRepair);
                        subjectDecodeRow(in.data(), got.data(), sourceWidth, processWidth,
                                         premultiplied, encoding, transform, watch, gotPeak,
                                         gotRepair, scratch);

                        if (!identical(wanted, got, "decode", where, reported)) {
                            decodeAgrees = false;
                        }
                        if (wantedRepair != gotRepair) {
                            std::printf("       %s: repair reported as %d, was %d\n", where,
                                        gotRepair, wantedRepair);
                            repairAgrees = false;
                        }
                        if (!sameFloat(wantedPeak, gotPeak)) {
                            std::printf("       %s: peak is %.9g, was %.9g\n", where, gotPeak,
                                        wantedPeak);
                            peakAgrees = false;
                        }

                        // The engine's output has the frame's processed width, so the decoded
                        // frame is the right shape to send back the other way.
                        std::vector<float> wantedSpan(
                            static_cast<size_t>(processWidth) * 4, 7.0f);
                        std::vector<float> gotSpan(static_cast<size_t>(processWidth) * 4, 7.0f);
                        referenceEncodeRow(wanted.data(), wantedSpan.data(), processWidth,
                                           premultiplied, encoding, transform);
                        subjectEncodeRow(got.data(), gotSpan.data(), processWidth,
                                         premultiplied, encoding, transform);
                        if (!identical(wantedSpan, gotSpan, "encode", where, reported)) {
                            encodeAgrees = false;
                        }

                        // `writeStripRows` resamples into the host's span and then encodes that
                        // span over itself, so the aliased call has to land where the separate
                        // one does.
                        std::vector<float> inPlace = got;
                        subjectEncodeRow(inPlace.data(), inPlace.data(), processWidth,
                                         premultiplied, encoding, transform);
                        if (!identical(gotSpan, inPlace, "encode in place", where, reported)) {
                            inPlaceAgrees = false;
                        }

                        // What the ENCODE_OUT kernel variants do instead of the host's encode.
                        // The engine's plain float path floors the developed pixel at zero and
                        // the encoding path floors it in the same place, so both sides are held
                        // to the same light: `delivered` is the frame the host would have been
                        // handed, and the question is only whether the coefficient form of the
                        // curve lands where libm's closed form does.
                        std::vector<float> delivered = got;
                        for (int i = 0; i < processWidth; ++i) {
                            for (int c = 0; c < 3; ++c) {
                                float &value = delivered[i * 4 + c];
                                value = value > 0 ? value : 0.0f;
                            }
                        }
                        std::vector<float> hostEncoded(
                            static_cast<size_t>(processWidth) * 4, 7.0f);
                        std::vector<float> kernelEncoded(
                            static_cast<size_t>(processWidth) * 4, 7.0f);
                        subjectEncodeRow(delivered.data(), hostEncoded.data(), processWidth,
                                         premultiplied, encoding, transform);
                        kernelEncodeRow(delivered.data(), kernelEncoded.data(), processWidth,
                                        premultiplied, curve, transform);

                        for (size_t i = 0; i < hostEncoded.size(); ++i) {
                            const double host = hostEncoded[i], kernel = kernelEncoded[i];
                            // A NaN reaches here only from a NaN the host handed in, and the two
                            // sides then disagree over which arm of the curve a NaN takes rather
                            // than over the curve. A developed pixel cannot be one — the floor
                            // above is `max`, and every value below is finite — so it is not
                            // what this is measuring.
                            if (std::isnan(host) || std::isnan(kernel)) continue;
                            if (host == kernel) continue;
                            if (std::isinf(host) || std::isinf(kernel)) {
                                // One side finite and the other not is a real disagreement, and
                                // no absolute difference describes it.
                                exactShapesAreExact = false;
                                if (reported++ < 4) {
                                    std::printf("       %s, coefficient encode: float %zu is "
                                                "%.9g, was %.9g\n", where, i, kernel, host);
                                }
                                continue;
                            }
                            const double gap = std::fabs(host - kernel);
                            // One unit of the delivery is the dividing line, not because the
                            // encodings all end there — DaVinci Intermediate and ACEScct do not
                            // — but because a value past it is already outside anything a frame
                            // could be written as.
                            if (std::fabs(host) <= 1.0 && gap > worstDeliveryGap) {
                                worstDeliveryGap = gap;
                                worstCoefficientWhere = kEncodingNames[e];
                                worstHost = host;
                                worstKernel = kernel;
                                for (int c = 0; c < 4; ++c) {
                                    worstDelivered[c] = delivered[(i / 4) * 4 + c];
                                }
                            }
                            // Above that line and only above it: dividing a gap by a result near
                            // zero measures the cancellation in the subtraction rather than
                            // anything about the curve, and the absolute bound already covers
                            // everything small.
                            if (std::fabs(host) > 1.0) {
                                const double relative = gap / std::fabs(host);
                                if (relative > worstRelativeGap) worstRelativeGap = relative;
                            }
                            // Only the two logarithmic curves are allowed to move at all: the
                            // others are the same arithmetic in a different order.
                            if (curve.shape != 2) exactShapesAreExact = false;
                        }

                        std::vector<float> decodeInPlace = in;
                        decodeInPlace.resize(static_cast<size_t>(sourceWidth) * 4);
                        std::vector<float> decodeApart(static_cast<size_t>(sourceWidth) * 4,
                                                       7.0f);
                        fotufilm::decodePixels(encoding, transform, in.data(),
                                              decodeApart.data(), sourceWidth, premultiplied,
                                              watch);
                        fotufilm::decodePixels(encoding, transform, decodeInPlace.data(),
                                              decodeInPlace.data(), sourceWidth, premultiplied,
                                              watch);
                        if (!identical(decodeApart, decodeInPlace, "decode in place", where,
                                       reported)) {
                            inPlaceAgrees = false;
                        }
                    }
                }
            }
        }
    }

    check(decodeAgrees, "the decode is bit for bit the pass-at-a-time decode it replaced");
    check(encodeAgrees, "and the encode is bit for bit the one it replaced");
    check(inPlaceAgrees, "converting a row over itself lands where converting apart does");
    check(repairAgrees, "a repaired pixel is still reported as repaired");
    check(peakAgrees, "and the over-range peak is the same float");
    check(exactShapesAreExact,
          "the coefficient form of an identity or power-law curve is exactly the host's");
    std::printf("       inside the delivery range the two logarithmic curves are within %.3g "
                "of the host's double, %.2f%% of a 16-bit LSB (worst: %s)\n",
                worstDeliveryGap, 100.0 * worstDeliveryGap / lsb16,
                worstCoefficientWhere[0] ? worstCoefficientWhere : "none");
    if (worstDeliveryGap > 0) {
        std::printf("       on %.9g %.9g %.9g / %.9g: %.9g, was %.9g\n",
                    worstDelivered[0], worstDelivered[1], worstDelivered[2],
                    worstDelivered[3], worstKernel, worstHost);
    }
    std::printf("       and over everything, including the pixels no host could send, "
                "within %.3g relative\n", worstRelativeGap);
    check(worstDeliveryGap < 0.1 * lsb16,
          "and the logarithmic ones stay inside a tenth of a 16-bit LSB");
    // A float carries about 1.19e-7 per ulp, so this is a couple of them — the regrouping is
    // three float operations where the host has one double one, and none of them may compound.
    check(worstRelativeGap < 5e-7,
          "and stay within a few ulps of it everywhere else");

    testDeviceDecodeParity(check);

    if (const char *bench = std::getenv("FOTUFILM_TRANSCODE_BENCH")) {
        if (bench[0] == '1') reportThroughput();
    }
}

}  // namespace fotufilm_test
