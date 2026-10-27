#ifndef FOTUFILM_HALIDE_STAGES_PRINT_H
#define FOTUFILM_HALIDE_STAGES_PRINT_H

#include "FotufilmHalide.h"
#include "Math.h"
#include "Curves.h"

#include <Halide.h>

namespace fotufilm {

inline Halide::Expr transmittance_of(Halide::Expr density, bool approximate = false) {
    return fs_pow10(-density, approximate);
}

inline Halide::Expr density_of(Halide::Expr transmittance, bool approximate = false) {
    return -fs_log10(Halide::max(transmittance, 1.0e-6f), approximate);
}

inline Halide::Expr print_mtf_read(Halide::ImageParam &configuration,
                                   Halide::Expr transmittance, Halide::Expr spread) {
    Halide::Expr keep = configuration(FOTUFILM_CONFIG_PRINT_SHARPEN);
    return Halide::select(keep > 0.0f, spread + keep * (transmittance - spread), spread);
}

/// Shadow and Highlight Detail (FOTUFILM_CONFIG_PRINT_DETAIL): how far a pixel's log exposure
/// moves, positive where the shadows are held back and negative where the highlights burn in.
/// Every argument is a log exposure on one axis on which more prints darker: the pixel's `at`,
/// the film's mid-grey `mid`, the film extreme that prints darkest `black`, and the highlight
/// `knee` and `white`.
///
/// Shadows: the knee sits a fixed share of the way from mid-grey to black, and the hold is a
/// smooth bump from there to black — nothing above the knee, nothing at black, most three fifths
/// of the way down. Highlights: past the knee the exposure `x` beyond it is drawn in to
/// `W x / (x + W)`, `W` the knee's room to the white: the slope matches at the knee and falls off
/// slowly, so highlights roll toward the white, still apart, rather than clip. Mirrors
/// `PrintDetail.hold` expression for expression; zero strengths hold nothing, bit for bit.
inline Halide::Expr print_detail_hold(Halide::ImageParam &configuration, Halide::Expr at,
                                      Halide::Expr mid, Halide::Expr black,
                                      Halide::Expr knee, Halide::Expr white) {
    using Halide::Expr;
    Expr shadows = configuration(FOTUFILM_CONFIG_PRINT_DETAIL);
    Expr highlights = configuration(FOTUFILM_CONFIG_PRINT_DETAIL + 1);
    // PrintDetail.shadowKneeShare, .reach and .peak.
    constexpr float kShadowKneeShare = 0.2f, kReach = 0.3f, kPeak = 0.18592f;
    Expr shadow_knee = mid + kShadowKneeShare * (black - mid);
    Expr span = black - shadow_knee;
    Expr u = Halide::clamp((at - shadow_knee) / Halide::max(span, 1.0e-3f), 0.0f, 1.0f);
    Expr bump = u * Halide::sqrt(u) * (1.0f - u) * (1.0f / kPeak);
    Expr hold = Halide::select(shadows > 0.0f && span > 0.05f,
                               shadows * kReach * span * bump, 0.0f);

    Expr room = knee - white;
    Expr past = Halide::max(knee - at, 0.0f);
    // What the roll-off takes back: x - W x / (x + W).
    Expr burn = Halide::select(highlights > 0.0f && room > 0.05f,
                               highlights * past * past / (past + room), 0.0f);
    return hold - burn;
}

/// The luminance-weighted paper exposure the detail controls key a print on
/// (`PrintDetail.weights`).
inline Halide::Expr print_detail_key(Halide::Expr red, Halide::Expr green, Halide::Expr blue) {
    return 0.25f * red + 0.65f * green + 0.10f * blue;
}

/// A directly viewed transparency's key: the optical density of its displayed luminance
/// (`PrintFinish.luminance`), on which a denser pixel shows darker.
inline Halide::Expr view_detail_key(Halide::Expr red, Halide::Expr green, Halide::Expr blue,
                                    bool approximate = false) {
    Halide::Expr luminance = 0.2289746f * red + 0.6917385f * green + 0.0792869f * blue;
    return -fs_log10(Halide::max(luminance, 1.0e-6f), approximate);
}

inline Halide::Expr paper_activation(Halide::ImageParam &configuration,
                                     Halide::Func paper_curve, Halide::Expr channel,
                                     Halide::Expr relative,
                                     bool approximate = false,
                                     Halide::Expr hold = Halide::Expr()) {
    Halide::Expr base = paper_curve_base(channel);
    Halide::Expr exposure = paper_exposure(configuration, channel, relative, approximate);
    // Shadow and Highlight Detail's hold, where the print compiles one.
    if (hold.defined()) exposure -= hold;
    return (sample_curve(paper_curve, exposure, channel) - configuration(base))
        / curve_range(configuration, base);
}

inline Halide::Expr texture_carry(Halide::Expr source, Halide::Expr developed,
                                  Halide::Expr flat, Halide::Expr reversal) {
    Halide::Expr difference = developed - flat;
    Halide::Expr signed_difference = Halide::select(reversal != 0, -difference, difference);
    return source * Halide::exp(signed_difference * 2.3025851f);
}

/// A scanned negative's light controls on display-linear print RGB (FOTUFILM_CONFIG_PRINT_FINISH):
/// gains, then highlights and shadows moving the ends of the print's luminance in stops about
/// mid-grey, then saturation and vibrance. Mirrors `PrintFinish.apply` expression for expression.
/// All-zero slots return `red`, `green` and `blue` untouched, bit for bit.
inline Halide::Expr print_finish(Halide::ImageParam &configuration, Halide::Expr channel,
                                 Halide::Expr red, Halide::Expr green, Halide::Expr blue,
                                 bool approximate = false) {
    using Halide::Expr;
    auto slot = [&](int index) { return configuration(FOTUFILM_CONFIG_PRINT_FINISH + index); };
    // Display P3 luminance, PrintFinish.luminance.
    constexpr float kR = 0.2289746f, kG = 0.6917385f, kB = 0.0792869f;
    Expr r = red * (1.0f + slot(0)), g = green * (1.0f + slot(1)), b = blue * (1.0f + slot(2));
    Expr luminance = kR * r + kG * g + kB * b;
    Expr stops = fs_log(Halide::max(luminance, 1.0e-6f) * (1.0f / 0.18f), approximate)
        * (1.0f / 0.6931472f);
    auto ease = [](Expr t) {
        Expr x = Halide::clamp(t, 0.0f, 1.0f);
        return x * x * (3.0f - 2.0f * x);
    };
    // PrintFinish.endStops over highlightReach above mid-grey and shadowReach below.
    Expr moved = slot(3) * 0.75f * ease(stops * (1.0f / 3.0f))
        + slot(4) * 0.75f * ease(-stops * (1.0f / 4.0f));
    Expr tone = Halide::select(luminance > 1.0e-6f,
                               fs_exp(moved * 0.6931472f, approximate), 1.0f);
    Expr r1 = r * tone, g1 = g * tone, b1 = b * tone;
    Expr luma = kR * r1 + kG * g1 + kB * b1;
    Expr peak = Halide::max(r1, Halide::max(g1, b1));
    Expr colourfulness = (peak - Halide::min(r1, Halide::min(g1, b1)))
        / Halide::max(peak, 1.0e-6f);
    Expr chroma = (1.0f + slot(5)) * (1.0f + slot(6) * (1.0f - colourfulness));
    Expr finished = luma + chroma * (Halide::mux(channel, {r1, g1, b1}) - luma);
    Expr neutral = slot(0) == 0.0f && slot(1) == 0.0f && slot(2) == 0.0f && slot(3) == 0.0f
        && slot(4) == 0.0f && slot(5) == 0.0f && slot(6) == 0.0f;
    return Halide::select(neutral, Halide::mux(channel, {red, green, blue}), finished);
}

}

#endif
