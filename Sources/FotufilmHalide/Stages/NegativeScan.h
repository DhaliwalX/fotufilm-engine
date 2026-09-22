#ifndef FOTUFILM_NEGATIVE_SCAN_STAGE_H
#define FOTUFILM_NEGATIVE_SCAN_STAGE_H
#include "Transfer.h"

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
}
#endif
