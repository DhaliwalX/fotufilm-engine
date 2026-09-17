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

inline Halide::Expr texture_carry(Halide::Expr source, Halide::Expr developed,
                                  Halide::Expr flat, Halide::Expr reversal) {
    Halide::Expr difference = developed - flat;
    Halide::Expr signed_difference = Halide::select(reversal != 0, -difference, difference);
    return source * Halide::exp(signed_difference * 2.3025851f);
}

}

#endif
