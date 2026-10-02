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

inline Halide::Expr paper_activation(Halide::ImageParam &configuration,
                                     Halide::Func paper_curve, Halide::Expr channel,
                                     Halide::Expr relative,
                                     bool approximate = false) {
    Halide::Expr base = paper_curve_base(channel);
    Halide::Expr exposure = paper_exposure(configuration, channel, relative, approximate);
    return (sample_curve(paper_curve, exposure, channel) - configuration(base))
        / curve_range(configuration, base);
}

// A circular clustered-dot screen. The rank is the area of a circle clipped by its
// unit square cell, so a flat tint has the requested ink coverage even as dots join.
// All coordinates are absolute frame pixels; there is no random or per-tile phase.
inline Halide::Expr newsprint_dot(Halide::Expr coverage, Halide::Expr x, Halide::Expr y,
                                  Halide::Expr pitch, float cosine, float sine) {
    using namespace Halide;
    Expr amount = clamp(coverage, 0.0f, 1.0f);
    // Modest, explicitly stylized dot gain on absorbent newsprint.
    amount = amount + 0.12f * amount * (1.0f - amount);
    Expr period = max(pitch, 0.001f);
    Expr u = (cast<float>(x) + 0.5f) / period;
    Expr v = (cast<float>(y) + 0.5f) / period;
    Expr a = cosine * u + sine * v;
    Expr b = -sine * u + cosine * v;
    Expr dx = a - floor(a) - 0.5f;
    Expr dy = b - floor(b) - 0.5f;
    Expr r2 = dx * dx + dy * dy;
    Expr radius = sqrt(max(r2, 0.25f));
    Expr segment = r2 * acos(clamp(0.5f / radius, 0.0f, 1.0f))
        - 0.5f * sqrt(max(r2 - 0.25f, 0.0f));
    Expr rank = 3.14159265f * r2 - select(r2 > 0.25f, 4.0f * segment, 0.0f);
    Expr edge = 0.8f / period;
    Expr t = clamp((amount - rank) / edge + 0.5f, 0.0f, 1.0f);
    Expr ink = t * t * (3.0f - 2.0f * t);
    // Unresolvable dots become mean coverage instead of aliasing in small previews.
    Expr resolved = clamp((period - 2.0f) / 2.0f, 0.0f, 1.0f);
    return strict_float(select(amount <= 0.0f, 0.0f, amount >= 1.0f, 1.0f,
                              amount + resolved * (ink - amount)));
}

// Display-linear P3 approximations of opaque colored dots on black paper and
// black ink on warm paper. The positive comes from the existing print receiver
// (or direct slide view); neither style claims measured press or pigment data.
inline Halide::Expr newsprint_read(Halide::ImageParam &configuration,
                                   Halide::Expr x, Halide::Expr y, Halide::Expr channel,
                                   Halide::Expr red, Halide::Expr green, Halide::Expr blue) {
    using namespace Halide;
    Expr pitch = configuration(FOTUFILM_CONFIG_NEWSPRINT + 1);
    Expr r = clamp(red, 0.0f, 1.0f), g = clamp(green, 0.0f, 1.0f);
    Expr b = clamp(blue, 0.0f, 1.0f);
    // Opaque RGB ink coverage grows toward the highlights, revealing the black
    // substrate between dots. Subtractive CMYK cannot brighten a black sheet.
    Expr rr = newsprint_dot(r, x, y, pitch, 0.965925826f, 0.258819045f);
    Expr gg = newsprint_dot(g, x, y, pitch, 0.258819045f, 0.965925826f);
    Expr bb = newsprint_dot(b, x, y, pitch, 1.0f, 0.0f);
    Expr colored = 0.003f + 0.877f * mux(channel, {rr, gg, bb});
    Expr luma = 0.22897456f * r + 0.69173852f * g + 0.07928691f * b;
    Expr k = newsprint_dot(1.0f - luma, x, y, pitch, 0.707106781f, 0.707106781f);
    Expr paper = mux(channel, {0.88f, 0.84f, 0.73f});
    Expr monochrome = paper * (1.0f - 0.935f * k);
    return select(configuration(FOTUFILM_CONFIG_NEWSPRINT) > 1.5f, monochrome, colored);
}

inline Halide::Expr texture_carry(Halide::Expr source, Halide::Expr developed,
                                  Halide::Expr flat, Halide::Expr reversal) {
    Halide::Expr difference = developed - flat;
    Halide::Expr signed_difference = Halide::select(reversal != 0, -difference, difference);
    return source * Halide::exp(signed_difference * 2.3025851f);
}

}

#endif
