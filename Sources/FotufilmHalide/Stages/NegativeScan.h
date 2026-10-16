#ifndef FOTUFILM_NEGATIVE_SCAN_STAGE_H
#define FOTUFILM_NEGATIVE_SCAN_STAGE_H
#include "Transfer.h"
#include "Math.h"

namespace fotufilm {
// Extended colour-managed RGB can contain negative or clipped channels. Those
// are not an invalid pixel: the automatic heuristic clamps each channel at zero.
// Only nonfinite/unbounded samples and wholly unlit triplets are discarded.
inline Halide::Expr negative_scan_valid(Halide::Expr r, Halide::Expr g, Halide::Expr b) {
    using namespace Halide;
    return r > -1e20f && r < 1e20f && g > -1e20f && g < 1e20f &&
           b > -1e20f && b < 1e20f && max(r, max(g, b)) > 0.0f;
}
// Independent adaptation of Lin & Tretter, PICS 1998, pp. 399–404.
// Robust endpoints come from one whole-frame preview, never from each render tile.
// See docs/automatic-negative-conversion.md for equations, defaults and limitations.
inline Halide::Expr negative_scan_channel(Halide::Expr sample, Halide::Expr low,
                                         Halide::Expr high, Halide::Expr contrast) {
    using namespace Halide;
    Expr a = srgb_encode(max(low, 0.0f));
    Expr b = srgb_encode(max(high, 0.0f));
    Expr span = max(b - a, 1e-6f);
    Expr inverted = (b - srgb_encode(max(sample, 0.0f))) / span;
    // A C1 continuous exponential extension reserves the outer 2% for outliers.
    // This explicit shoulder is our implementation choice, not a formula in the paper.
    constexpr float room = 0.02f;
    constexpr float slope = 1.0f - 2.0f * room;
    Expr middle = room + slope * inverted;
    Expr soft = select(inverted < 0.0f,
        room * exp(max(-80.0f, min(0.0f, inverted * (slope / room)))),
        inverted > 1.0f,
        1.0f - room * exp(max(-80.0f, min(0.0f, (1.0f - inverted) * (slope / room)))),
        middle);
    Expr x = clamp(soft, 0.0f, 1.0f);
    // Published symmetric inverse-sigmoid. c is tunable; 0.6 is our initial default.
    Expr y = select(x <= 0.5f, 0.5f * pow(max(2.0f*x, 0.0f), contrast),
                    1.0f - 0.5f * pow(max(2.0f-2.0f*x, 0.0f), contrast));
    // A flat channel has no identifiable range: do not turn grain into full contrast.
    y = select(high - low < max(high, 1e-6f) * 0.02f, 0.5f, y);
    return srgb_decode(y);
}

// One channel's density of `sample` over the clear film `clear`.
inline Halide::Expr scan_density_over_clear(Halide::Expr sample, Halide::Expr clear,
                                            bool approximate) {
    using namespace Halide;
    return -fs_log10(max(sample, 1e-30f) / clear, approximate);
}

// FOTUFILM_CONFIG_SCAN_READING: how a scanned negative's linear scan RGB is read.
enum ScanReadingMode { kScanUnread = 0, kScanFilm = 1 };

inline Halide::Expr scan_reading_mode(Halide::ImageParam &configuration) {
    return Halide::cast<int32_t>(configuration(FOTUFILM_CONFIG_SCAN_READING) + 0.5f);
}

inline Halide::Expr scan_reading_slot(Halide::ImageParam &configuration, int offset,
                                      Halide::Expr index) {
    return configuration(FOTUFILM_CONFIG_SCAN_READING + offset + index);
}

// Whether a film reading can place the sample: every channel inside the usable range, which a
// nonfinite sample is not. ApproximateNegativeScan.density(of:) returns nil otherwise.
inline Halide::Expr scan_film_readable(Halide::ImageParam &configuration,
                                       Halide::Expr r, Halide::Expr g, Halide::Expr b) {
    using namespace Halide;
    auto inside = [&](int channel, Expr value) {
        return value > scan_reading_slot(configuration, 13, channel)
            && value < scan_reading_slot(configuration, 16, channel);
    };
    return inside(0, r) && inside(1, g) && inside(2, b);
}

// One record's density from the scan: its base density plus its gain times its weighted density
// of the scan channels over the clear film (FOTUFILM_CONFIG_SCAN_CROSSTALK), held inside the
// negative interchange range; the base where the sample cannot be read, which then prints black.
// Mirrors ApproximateNegativeScan.density(of:).
inline Halide::Expr scan_film_density(Halide::ImageParam &configuration, Halide::Expr record,
                                      Halide::Expr r, Halide::Expr g, Halide::Expr b,
                                      bool approximate) {
    using namespace Halide;
    auto scanner = [&](int channel, Expr sample) {
        return scan_density_over_clear(sample, scan_reading_slot(configuration, 1, channel),
                                       approximate);
    };
    auto weight = [&](int channel) {
        return configuration(FOTUFILM_CONFIG_SCAN_CROSSTALK + record * 3 + channel);
    };
    Expr read = weight(0) * scanner(0, r) + weight(1) * scanner(1, g) + weight(2) * scanner(2, b);
    Expr base = scan_reading_slot(configuration, 4, record);
    // NegativeInterchange.range.
    Expr density = clamp(base + scan_reading_slot(configuration, 10, record) * read, -0.5f, 8.0f);
    return select(scan_film_readable(configuration, r, g, b), density, base);
}

// One channel's scene light from a plain reading of its `density` over the clear film, weighted
// across the channels against their crosstalk: that density times `gain`, back to light along a
// straight-line negative with the densest end, density `reference`, at diffuse white. Mirrors
// PlainNegativeScan.light(of:); the caller blacks out a pixel where any channel passes no light.
inline Halide::Expr plain_negative_light(Halide::Expr density, Halide::Expr gain,
                                         Halide::Expr reference, bool approximate) {
    using namespace Halide;
    // PlainNegativeScan.gamma and .highlight.
    constexpr float kGamma = 0.6f;
    constexpr float kHighlight = 0.18f * 5.656854f;
    return kHighlight * fs_pow10((gain * density - reference) * (1.0f / kGamma), approximate);
}
}
#endif
