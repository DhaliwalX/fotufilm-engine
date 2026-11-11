#ifndef FOTUFILM_HALIDE_STAGES_DEVELOPMENT_H
#define FOTUFILM_HALIDE_STAGES_DEVELOPMENT_H

#include "FotufilmHalide.h"
#include "Curves.h"
#include "Couplers.h"

#include <Halide.h>

namespace fotufilm {

inline Halide::Expr film_activation(Halide::ImageParam &configuration,
                                    Halide::Expr channel, Halide::Expr formed) {
    Halide::Expr base = FOTUFILM_CONFIG_CURVES + channel * 6;
    return (formed - configuration(base)) / film_curve_range(configuration, channel);
}

inline Halide::Expr donor_activation(Halide::ImageParam &configuration,
                                     Halide::Expr donor_index, Halide::Expr formed) {
    return (formed - donor_curve_dmin(configuration, donor_index))
        / Halide::max(donor_curve_range(configuration, donor_index), 1.0e-6f);
}

template <typename FilmCurveFn, typename DonorCurveFn>
inline Halide::Expr forward_neutral_compensation(
    Halide::ImageParam &configuration, Halide::Expr channel, Halide::Expr log_exposure,
    FilmCurveFn &&film_curve_fn, DonorCurveFn &&donor_curve_fn,
    Halide::Expr on_couplers, Halide::Expr on_donor, int max_donors) {
    Halide::Expr coupler_sum = 0.0f;
    for (int j = 0; j < 3; ++j) {
        Halide::Expr act_j = film_activation(configuration, j, film_curve_fn(j, log_exposure));
        Halide::Expr rel_j = coupler_release(configuration, j, act_j);
        coupler_sum = coupler_sum
            + configuration(FOTUFILM_CONFIG_COUPLER + channel * 3 + j) * rel_j;
    }
    Halide::Expr sum = Halide::select(on_couplers, coupler_sum, 0.0f);
    if (max_donors > 0) {
        Halide::Expr donor_count = Halide::clamp(
            Halide::cast<int32_t>(configuration(FOTUFILM_CONFIG_DONOR_COUNT)), 0, max_donors);
        Halide::Expr donor_sum = 0.0f;
        for (int m = 0; m < max_donors; ++m) {
            Halide::Expr act_m = donor_activation(
                configuration, m, donor_curve_fn(m, log_exposure));
            Halide::Expr rel_m = donor_release(configuration, m, act_m);
            donor_sum = donor_sum + Halide::select(
                m < donor_count,
                donor_release_amplitude(configuration, channel, m) * rel_m,
                0.0f);
        }
        sum = sum + Halide::select(on_donor, donor_sum, 0.0f);
    }
    return configuration(FOTUFILM_CONFIG_COUPLER_EFFECTIVE_SCALE + channel) * sum;
}

inline Halide::Expr donor_inhibition(Halide::ImageParam &configuration,
                                     Halide::Expr channel, Halide::Expr donor_released) {
    return configuration(FOTUFILM_CONFIG_DONOR_RELEASE + channel) * donor_released
        * configuration(FOTUFILM_CONFIG_COUPLER_SCALE);
}

inline Halide::Expr fringe_inhibition(Halide::ImageParam &configuration,
                                      Halide::Expr channel, Halide::Expr inhibition,
                                      Halide::Expr fringe_radius,
                                      Halide::Expr delta0, Halide::Expr delta1,
                                      Halide::Expr delta2) {
    Halide::Expr fringe = chromatic_fringe_inhibition(
        configuration, channel, delta0, delta1, delta2);
    return Halide::select(fringe_radius > 0, inhibition + fringe, inhibition);
}

inline Halide::Expr inhibited_log_exposure(Halide::ImageParam &configuration,
                                           Halide::Expr channel, Halide::Expr log_exposure,
                                           Halide::Expr inhibition) {
    Halide::Expr u = log_exposure - inhibition;
    return u + coupler_warp(configuration, channel, u);
}

inline Halide::Expr adjacency_shift(Halide::ImageParam &configuration,
                                    Halide::Expr residual) {
    return Halide::select(
        configuration(FOTUFILM_CONFIG_ADJACENCY_MODEL) > 0.5f, 0.0f,
        -configuration(FOTUFILM_CONFIG_ADJACENCY_STRENGTH) * residual);
}

inline Halide::Expr developed_density(Halide::ImageParam &configuration,
                                      Halide::Expr channel, Halide::Expr formed) {
    Halide::Expr base = FOTUFILM_CONFIG_CURVES + channel * 6;
    Halide::Expr d_min = configuration(base);
    Halide::Expr range = film_curve_range(configuration, channel);
    return Halide::select(
        configuration(FOTUFILM_CONFIG_DEVELOP_COMPLEMENT) > 0.5f,
        d_min + range - (formed - d_min), formed);
}

struct DensityPosition {
    Halide::Expr amount, net;
};

inline DensityPosition density_position(Halide::ImageParam &configuration,
                                        Halide::Expr channel, Halide::Expr density) {
    Halide::Expr base = FOTUFILM_CONFIG_CURVES + channel * 6;
    Halide::Expr range = film_curve_range(configuration, channel);
    Halide::Expr amount = Halide::clamp(
        (density - configuration(base)) / range, 0.0f, 1.0f);
    return {amount, amount * range};
}

}

#endif
